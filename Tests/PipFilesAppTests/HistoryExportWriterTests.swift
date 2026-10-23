import Darwin
import Foundation
import XCTest
@testable import PipFiles

final class HistoryExportWriterTests: XCTestCase {
    private func workspace() throws -> (root: URL, exports: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipHistoryExportTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("SavedData", isDirectory: true)
        let exports = base.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        return (root, exports)
    }

    func testExclusiveExportWritesExactBytesWithPrivatePermissions() throws {
        let (root, exports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let destination = exports.appendingPathComponent("history.json")
        let bytes = Data("{\"actions\":[]}".utf8)

        try HistoryExclusiveWriter.save(bytes, to: destination, outside: root)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingFileAndFinalSymlinkCannotBeReplaced() throws {
        let (root, exports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let existing = exports.appendingPathComponent("existing.json")
        let original = Data("original".utf8)
        try original.write(to: existing)
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("new".utf8), to: existing, outside: root)) {
            guard case HistoryExclusiveWriter.ExportError.existingFile = $0 else {
                return XCTFail("Expected existing-file refusal, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)

        let link = exports.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("new".utf8), to: link, outside: root))
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), existing.path)
    }

    func testSavedDataAndLinkedParentAreRefused() throws {
        let (root, exports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let inside = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let directTarget = inside.appendingPathComponent("report.json")
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("report".utf8), to: directTarget, outside: root)) {
            guard case HistoryExclusiveWriter.ExportError.protectedLocation = $0 else {
                return XCTFail("Expected protected-location refusal, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directTarget.path))

        // APFS commonly ignores case, but a string-prefix guard must still
        // recognize a differently-cased spelling of the protected root.
        let aliasedRoot = root.path.uppercased()
        let rootMetadata = try FileManager.default.attributesOfItem(atPath: root.path)
        let aliasMetadata = try? FileManager.default.attributesOfItem(atPath: aliasedRoot)
        let sameDirectory: Bool = {
            guard let rootDevice = (rootMetadata[.systemNumber] as? NSNumber)?.uint64Value,
                  let aliasDevice = (aliasMetadata?[.systemNumber] as? NSNumber)?.uint64Value,
                  let rootInode = (rootMetadata[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let aliasInode = (aliasMetadata?[.systemFileNumber] as? NSNumber)?.uint64Value else { return false }
            return rootDevice == aliasDevice && rootInode == aliasInode
        }()
        if sameDirectory {
            let caseAliasTarget = URL(fileURLWithPath: aliasedRoot).appendingPathComponent("case-alias.json")
            XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("report".utf8),
                                                                    to: caseAliasTarget, outside: root)) {
                guard case HistoryExclusiveWriter.ExportError.protectedLocation = $0 else {
                    return XCTFail("Expected case-aliased protected-location refusal, got \($0)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("case-alias.json").path))
        }

        let linkedParent = exports.appendingPathComponent("JournalLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: inside)
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("report".utf8),
                                                                to: linkedParent.appendingPathComponent("report.json"),
                                                                outside: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directTarget.path))

        // The final parent is a real directory; only an intermediate component
        // is linked into the data root, so canonicalization must catch it.
        let linkedAncestor = exports.appendingPathComponent("SavedDataLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: root)
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("report".utf8),
                                                                to: linkedAncestor.appendingPathComponent("Journal")
                                                                    .appendingPathComponent("report.json"),
                                                                outside: root)) {
            guard case HistoryExclusiveWriter.ExportError.protectedLocation = $0 else {
                return XCTFail("Expected canonical protected-location refusal, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directTarget.path))
    }

    func testPartialWriteRemainsAvailableForInspection() throws {
        let (root, exports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let destination = exports.appendingPathComponent("partial.json")
        XCTAssertThrowsError(try HistoryExclusiveWriter.save(Data("report".utf8),
                                                                to: destination, outside: root,
                                                                failAfterBytesForTesting: 3)) {
            guard case HistoryExclusiveWriter.ExportError.partialFile(let path) = $0 else {
                return XCTFail("Expected partial-file error, got \($0)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(path.hasSuffix("/partial.json"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("rep".utf8))
    }
}
