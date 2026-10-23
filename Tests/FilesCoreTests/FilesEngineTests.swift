import XCTest
import Darwin
import CryptoKit
@testable import FilesCore

final class FilesEngineTests: XCTestCase {
    private var root: URL!
    private var input: URL!
    private var output: URL!
    private var journal: URL!
    private var engine: FilesEngine!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let temporary = fm.temporaryDirectory.path
        let physical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        root = URL(fileURLWithPath: physical).appendingPathComponent("PipFilesTests-\(UUID().uuidString)")
        input = root.appendingPathComponent("in")
        output = root.appendingPathComponent("out")
        journal = root.appendingPathComponent("journal")
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        engine = FilesEngine(journalDirectory: journal)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func file(_ name: String, contents: String = "sample") throws -> URL {
        let url = input.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: url.path)
        return url
    }

    private func setXattr(_ name: String, data: Data, on url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            name.withCString { key in
                url.path.withCString { path in
                    setxattr(path, key, bytes.baseAddress, data.count, 0, 0)
                }
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func xattr(_ name: String, on url: URL) throws -> Data {
        let size = name.withCString { key in
            url.path.withCString { path in getxattr(path, key, nil, 0, 0, 0) }
        }
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { bytes in
            name.withCString { key in
                url.path.withCString { path in getxattr(path, key, bytes.baseAddress, size, 0, 0) }
            }
        }
        guard count == size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data
    }

    private func config(_ actions: [FileAction], predicates: [FilesCore.Predicate] = [.fileExtension("txt")],
                        match: MatchMode = .all) -> FolderConfig {
        FolderConfig(name: "Test folder", path: input.path,
                     rules: [Rule(name: "Rule", match: match, predicates: predicates, actions: actions)])
    }

    func testPreviewHasZeroWritesAndCopyIsIdempotent() throws {
        _ = try file("one.txt")
        let cfg = config([.copy(to: output.path)])
        let preview = try engine.preview(cfg)
        XCTAssertEqual(preview.rows.map(\.status), [.ready])
        XCTAssertFalse(fm.fileExists(atPath: journal.path))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: output.path).isEmpty)
        let results = try engine.apply(preview, config: cfg)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("one.txt")), "sample")
        XCTAssertEqual(try engine.preview(cfg).rows.first?.status, .skipped)
        XCTAssertEqual(try engine.history().count, 1)
    }

    func testCopyPreservesMetadataAndLeavesSourceUnchanged() throws {
        let source = try file("metadata.txt", contents: "data fork")
        let tags = try PropertyListSerialization.data(fromPropertyList: ["Blue\n4"], format: .binary, options: 0)
        try setXattr("com.apple.metadata:_kMDItemUserTags", data: tags, on: source)
        try setXattr("com.pipreps.copytest", data: Data("named attribute".utf8), on: source)
        try setXattr("com.apple.ResourceFork", data: Data("resource fork".utf8), on: source)
        XCTAssertEqual(chmod(source.path, 0o640), 0)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -45)], ofItemAtPath: source.path)
        let before = try SafeFileOperations.fingerprint(source)
        let cfg = config([.copy(to: output.path)])

        XCTAssertEqual(try engine.apply(engine.preview(cfg), config: cfg).count, 1)

        let copied = output.appendingPathComponent("metadata.txt")
        let after = try SafeFileOperations.fingerprint(copied)
        XCTAssertEqual(try SafeFileOperations.fingerprint(source), before)
        XCTAssertNotEqual(after.fileID, before.fileID)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.contentHash, before.contentHash)
        XCTAssertEqual(after.permissions, before.permissions)
        XCTAssertEqual(after.modifiedAt, before.modifiedAt)
        XCTAssertEqual(after.tags, before.tags)
        for key in ["com.apple.metadata:_kMDItemUserTags", "com.pipreps.copytest", "com.apple.ResourceFork"] {
            XCTAssertEqual(try xattr(key, on: copied), try xattr(key, on: source))
        }
    }

    func testCopyDoesNotOverwriteDestinationCreatedAfterPreview() throws {
        let source = try file("collision.txt", contents: "selected")
        let cfg = config([.copy(to: output.path)])
        let preview = try engine.preview(cfg)
        let destination = output.appendingPathComponent("collision.txt")
        try Data("existing".utf8).write(to: destination)

        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("selected".utf8))
    }

    func testFirstMatchingRuleWinsAndDisabledRuleIgnored() throws {
        _ = try file("report.txt", contents: "12345")
        var cfg = config([.copy(to: output.path)])
        cfg.rules.insert(Rule(name: "Disabled", enabled: false, predicates: [.fileExtension("txt")],
                              actions: [.rename(to: "bad.txt")]), at: 0)
        cfg.rules.append(Rule(name: "Later", predicates: [.minimumSize(0)], actions: [.rename(to: "bad.txt")]))
        XCTAssertEqual(try engine.preview(cfg).rows.first?.ruleName, "Rule")
    }

    func testAllAnyAndAgeSizePredicates() throws {
        _ = try file("notes.txt", contents: "12345")
        let all = config([.copy(to: output.path)], predicates: [.nameContains("NOT"), .minimumSize(5), .minimumAge(20)])
        XCTAssertEqual(try engine.preview(all).rows.first?.status, .ready)
        let none = config([.copy(to: output.path)], predicates: [.maximumSize(4), .maximumAge(2)])
        XCTAssertEqual(try engine.preview(none).rows.first?.status, .skipped)
        let any = config([.copy(to: output.path)], predicates: [.maximumSize(4), .minimumAge(20)], match: .any)
        XCTAssertEqual(try engine.preview(any).rows.first?.status, .ready)
    }

    func testStaleSourceAndDestinationConflictRefuseApply() throws {
        let source = try file("a.txt")
        let cfg = config([.move(to: output.path)])
        let preview = try engine.preview(cfg)
        try Data("changed".utf8).write(to: source)
        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: source.path)
        let fresh = try engine.preview(cfg)
        try Data("occupied".utf8).write(to: output.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try engine.apply(fresh, config: cfg))
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("a.txt")), "occupied")
    }

    func testPartialAndRecentFilesBlocked() throws {
        _ = try file("download.crdownload")
        let recent = input.appendingPathComponent("recent.txt")
        try Data("new".utf8).write(to: recent)
        let cfg = config([.copy(to: output.path)])
        let rows = try engine.preview(cfg).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.status == .blocked })
    }

    func testSymlinkSourceAndDestinationAncestorRejected() throws {
        let real = try file("real.txt")
        try fm.createSymbolicLink(at: input.appendingPathComponent("link.txt"), withDestinationURL: real)
        let rows = try engine.preview(config([.copy(to: output.path)])).rows
        XCTAssertEqual(rows.first(where: { $0.sourcePath.hasSuffix("link.txt") })?.status, .blocked)
        let linkedOutput = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedOutput, withDestinationURL: output)
        XCTAssertEqual(try engine.preview(config([.copy(to: linkedOutput.path)])).rows.first(where: { $0.sourcePath == real.path })?.status, .blocked)
    }

    func testRenameTraversalAndExistingDestinationBlocked() throws {
        _ = try file("a.txt")
        XCTAssertEqual(try engine.preview(config([.rename(to: "../escape.txt")])).rows.first?.status, .blocked)
        _ = try file("occupied.txt")
        let rows = try engine.preview(config([.rename(to: "occupied.txt")])).rows
        XCTAssertTrue(rows.allSatisfy { $0.status == .blocked || $0.status == .skipped })
    }

    func testMultiActionMoveRenameAndReverseUndo() throws {
        let source = try file("a.txt")
        let cfg = config([.move(to: output.path), .rename(to: "b.txt")])
        let preview = try engine.preview(cfg)
        XCTAssertEqual(preview.rows.first?.actions.count, 2)
        let records = try engine.apply(preview, config: cfg)
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("b.txt").path))
        let undone = try engine.undo(rowID: preview.rows[0].id)
        XCTAssertEqual(undone.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testUndoRefusesChangedResultAndOccupiedOriginal() throws {
        let source = try file("a.txt")
        let cfg = config([.move(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        try Data("changed".utf8).write(to: output.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try engine.undo(record.id))
        try Data("sample".utf8).write(to: output.appendingPathComponent("a.txt"))
        try fm.setAttributes([.modificationDate: record.after!.modifiedAt], ofItemAtPath: output.appendingPathComponent("a.txt").path)
        try Data("occupied".utf8).write(to: source)
        XCTAssertThrowsError(try engine.undo(record.id))
    }

    func testZipHasValidHeadersAndUndoRetainsUnchangedArchiveForRecovery() throws {
        let source = try file("a.txt", contents: "hello zip")
        let cfg = config([.zipArchive(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let zip = output.appendingPathComponent("a.txt.zip")
        let bytes = try Data(contentsOf: zip)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertTrue(bytes.range(of: Data("hello zip".utf8)) != nil)
        XCTAssertEqual(Array(bytes.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        let extracted = root.appendingPathComponent("unzip-extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        verify.arguments = ["-t", zip.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-qq", zip.path, "-d", extracted.path]
        extract.standardOutput = FileHandle.nullDevice
        extract.standardError = FileHandle.nullDevice
        try extract.run(); extract.waitUntilExit()
        XCTAssertEqual(extract.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("a.txt")), try Data(contentsOf: source))
        let undone = try engine.undo(record.id)
        XCTAssertFalse(fm.fileExists(atPath: zip.path))
        let recovery = try XCTUnwrap(undone.recoveryPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recovery)), bytes)
        XCTAssertEqual(try engine.history().first?.recoveryPath, recovery)
    }

    func testSourceNameReplacementBeforeMoveIsNotPlacedAtDestination() throws {
        let source = try file("a.txt", contents: "selected")
        let cfg = config([.move(to: output.path)])
        let preview = try engine.preview(cfg)
        let preserved = root.appendingPathComponent("selected-original")
        SafeFileOperations.beforeSourceStageRenameForTesting = { [self] in
            SafeFileOperations.beforeSourceStageRenameForTesting = nil
            try? fm.moveItem(at: source, to: preserved)
            try? Data("unrelated".utf8).write(to: source)
        }
        defer { SafeFileOperations.beforeSourceStageRenameForTesting = nil }

        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        let record = try XCTUnwrap(engine.history().first)
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertNotNil(record.stagingPath)
        XCTAssertEqual(try Data(contentsOf: source), Data("unrelated".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("selected".utf8))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testStageNameReplacementBeforeFinalMoveIsJournaledAndRetained() throws {
        _ = try file("a.txt", contents: "selected")
        let cfg = config([.move(to: output.path)])
        let preview = try engine.preview(cfg)
        let preserved = root.appendingPathComponent("selected-stage")
        SafeFileOperations.beforeFinalStageRenameForTesting = { [self] in
            SafeFileOperations.beforeFinalStageRenameForTesting = nil
            guard let stage = try? fm.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(".pip-files-stage-") }) else { return }
            try? fm.moveItem(at: stage, to: preserved)
            try? Data("unrelated".utf8).write(to: stage)
        }
        defer { SafeFileOperations.beforeFinalStageRenameForTesting = nil }

        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        let record = try XCTUnwrap(engine.history().first)
        XCTAssertEqual(record.state, .interrupted)
        let stage = try XCTUnwrap(record.stagingPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stage)), Data("unrelated".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("selected".utf8))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testRecoveryNameReplacementDuringUndoIsNeverDeleted() throws {
        _ = try file("a.txt", contents: "selected")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let preserved = root.appendingPathComponent("original-recovery")
        SafeFileOperations.beforeRecoveryVerificationForTesting = { [self] in
            SafeFileOperations.beforeRecoveryVerificationForTesting = nil
            guard let recovery = try? fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(".pip-files-undo-") }) else { return }
            try? fm.moveItem(at: recovery, to: preserved)
            try? Data("unrelated".utf8).write(to: recovery)
        }
        defer { SafeFileOperations.beforeRecoveryVerificationForTesting = nil }

        XCTAssertThrowsError(try engine.undo(record.id))
        let interrupted = try XCTUnwrap(engine.history().first)
        XCTAssertEqual(interrupted.state, .interrupted)
        let recovery = try XCTUnwrap(interrupted.recoveryPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recovery)), Data("unrelated".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("selected".utf8))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testOlderJournalRecordWithoutRecoveryFieldsStillLoads() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let journalFile = journal.appendingPathComponent(record.id.uuidString + ".json")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalFile)) as? [String: Any])
        old.removeValue(forKey: "stagingPath")
        old.removeValue(forKey: "undoStagingPath")
        old.removeValue(forKey: "recoveryPath")
        try JSONSerialization.data(withJSONObject: old).write(to: journalFile, options: .atomic)

        let loaded = try XCTUnwrap(engine.history().first)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertNil(loaded.recoveryPath)
    }

    func testCorruptJournalFailsClosed() throws {
        _ = try file("a.txt")
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: journal.appendingPathComponent("bad.json"))
        XCTAssertThrowsError(try engine.preview(config([.copy(to: output.path)]))) {
            XCTAssertEqual($0 as? FilesError, .journalCorrupt)
        }
    }

    func testInterruptedIntentIsSurfacedAndNeverReplayed() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let completed = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let url = journal.appendingPathComponent(completed.id.uuidString + ".json")
        var interrupted = completed
        interrupted.state = .intent
        interrupted.after = nil
        try JSONEncoder().encode(interrupted).write(to: url, options: .atomic)
        XCTAssertEqual(try engine.history().first?.state, .interrupted)
        XCTAssertEqual(try engine.preview(cfg).rows.first?.status, .skipped)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("a.txt")), "sample")
    }

    func testTwoSourcesCannotPlanSameRenamedDestination() throws {
        _ = try file("a.txt")
        _ = try file("b.txt")
        let cfg = config([.rename(to: "same.txt")])
        let rows = try engine.preview(cfg).rows
        XCTAssertEqual(rows.filter { $0.status == .ready }.count, 1)
        XCTAssertEqual(rows.filter { $0.status == .blocked }.count, 1)
    }

    func testTagAndUndoWhenFilesystemSupportsFinderTags() throws {
        let source = try file("a.txt")
        let cfg = config([.tag("Pip test")])
        let preview = try engine.preview(cfg)
        let record: OperationRecord
        do { record = try XCTUnwrap(engine.apply(preview, config: cfg).first) }
        catch { throw XCTSkip("Finder tags unavailable on this test volume: \(error)") }
        let tags = try source.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertTrue(tags.contains("Pip test"))
        _ = try engine.undo(record.id)
        let freshURL = URL(fileURLWithPath: source.path)
        let afterUndo = try freshURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertFalse(afterUndo.contains("Pip test"), "Tags after undo: \(afterUndo)")
    }

    func testReplacementWithIdenticalBytesAndTimestampIsStale() throws {
        let source = try file("a.txt")
        let cfg = config([.move(to: output.path)])
        let preview = try engine.preview(cfg)
        let date = try XCTUnwrap(preview.rows.first?.fingerprint?.modifiedAt)
        try fm.removeItem(at: source)
        try Data("sample".utf8).write(to: source)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testUndoRefusesReplacementWithIdenticalBytesAndTimestamp() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let result = output.appendingPathComponent("a.txt")
        let date = try XCTUnwrap(record.after?.modifiedAt)
        try fm.removeItem(at: result)
        try Data("sample".utf8).write(to: result)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: result.path)
        XCTAssertThrowsError(try engine.undo(record.id))
        XCTAssertTrue(fm.fileExists(atPath: result.path))
        XCTAssertEqual(try engine.history().first?.state, .completed)
    }

    func testUndoIntentSurfacesAfterInterruptedUndo() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let url = journal.appendingPathComponent(record.id.uuidString + ".json")
        var pending = record
        pending.state = .undoIntent
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        XCTAssertEqual(try engine.history().first?.state, .interrupted)
        XCTAssertThrowsError(try engine.undo(record.id))
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testInterruptedTagBlocksChangedFingerprintAndWatchReplay() throws {
        _ = try file("a.txt")
        let cfg = config([.tag("Pip test")])
        let record: OperationRecord
        do { record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first) }
        catch { throw XCTSkip("Finder tags unavailable on this test volume: \(error)") }
        let url = journal.appendingPathComponent(record.id.uuidString + ".json")
        var pending = record
        pending.state = .intent
        pending.after = nil
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        XCTAssertEqual(try engine.history().first?.state, .interrupted)
        let next = try engine.preview(cfg)
        XCTAssertNotEqual(next.rows.first?.status, .ready)
        XCTAssertTrue(try engine.apply(next, config: cfg).isEmpty)
    }

    func testRuleEditChangesLedgerKeyForSameSource() throws {
        _ = try file("a.txt")
        var cfg = config([.copy(to: output.path)])
        let first = try XCTUnwrap(engine.preview(cfg).rows.first?.ledgerKey)
        cfg.rules[0].name = "Edited label"
        XCTAssertEqual(try engine.preview(cfg).rows.first?.ledgerKey, first)
        cfg.rules[0].actions = [.zipArchive(to: output.path)]
        let second = try XCTUnwrap(engine.preview(cfg).rows.first?.ledgerKey)
        XCTAssertNotEqual(first, second)
    }

    func testCompletedTagDoesNotSuppressNewActionUnderSameRuleID() throws {
        _ = try file("a.txt")
        var cfg = config([.tag("Pip test")])
        do { _ = try engine.apply(engine.preview(cfg), config: cfg) }
        catch { throw XCTSkip("Finder tags unavailable on this test volume: \(error)") }
        XCTAssertEqual(try engine.preview(cfg).rows.first?.status, .skipped)
        cfg.rules[0].actions = [.copy(to: output.path)]
        let changed = try engine.preview(cfg)
        XCTAssertEqual(changed.rows.first?.status, .ready)
        XCTAssertEqual(try engine.apply(changed, config: cfg).count, 1)
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testSecondProcessLockRefusesApplyWithoutMutation() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let preview = try engine.preview(cfg)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        let fd = open(journal.appendingPathComponent(".engine.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("a.txt").path))
    }

    func testLegacyCompletedRecordStillPreventsDuplicateCopy() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let url = journal.appendingPathComponent(record.id.uuidString + ".json")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        payload.removeValue(forKey: "ruleSignature")
        payload["ledgerKey"] = "old-format-key"
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        XCTAssertEqual(try engine.preview(cfg).rows.first?.status, .skipped)
    }

    func testInPlaceEditDuringDescriptorReadIsRejected() throws {
        let source = try file("a.txt")
        SafeFileOperations.beforeFinalStatForTesting = {
            if let handle = try? FileHandle(forWritingTo: source) {
                try? handle.write(contentsOf: Data("other".utf8))
                try? handle.close()
            }
        }
        defer { SafeFileOperations.beforeFinalStatForTesting = nil }
        let row = try engine.preview(config([.copy(to: output.path)])).rows.first
        XCTAssertEqual(row?.status, .blocked)
        XCTAssertTrue(row?.issue?.contains("changed") == true)
    }

    func testUndoRefusesPermissionChangedResult() throws {
        _ = try file("a.txt")
        let cfg = config([.copy(to: output.path)])
        let record = try XCTUnwrap(engine.apply(engine.preview(cfg), config: cfg).first)
        let result = output.appendingPathComponent("a.txt")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: result.path)
        XCTAssertThrowsError(try engine.undo(record.id))
        XCTAssertTrue(fm.fileExists(atPath: result.path))
    }

    func testDirectorySwapCannotRedirectPreviewContentRead() throws {
        _ = try file("a.txt", contents: "safe")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("a.txt"))
        let backup = root.appendingPathComponent("original-inbox")
        SafeFileOperations.beforeEntryFingerprintForTesting = { [self] in
            SafeFileOperations.beforeEntryFingerprintForTesting = nil
            try? fm.moveItem(at: input, to: backup)
            try? fm.createSymbolicLink(at: input, withDestinationURL: outside)
        }
        defer { SafeFileOperations.beforeEntryFingerprintForTesting = nil }
        let cfg = config([.copy(to: output.path)])
        let preview = try engine.preview(cfg)
        let row = preview.rows.first
        let safeHash = SHA256.hash(data: Data("safe".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(row?.fingerprint?.contentHash, safeHash)
        XCTAssertThrowsError(try engine.apply(preview, config: cfg))
    }

    #if DEBUG
    func testChildStopsAfterSavedIntent() throws {
        guard let path = ProcessInfo.processInfo.environment["PIP_FILES_CRASH_CHILD_ROOT"] else {
            throw XCTSkip("Only selected by the crash/relaunch subprocess test")
        }
        let crashRoot = URL(fileURLWithPath: path)
        let config = try JSONDecoder().decode(FolderConfig.self,
                                              from: Data(contentsOf: crashRoot.appendingPathComponent("config.json")))
        let crashEngine = FilesEngine(journalDirectory: crashRoot.appendingPathComponent("journal"))
        FilesEngine.afterIntentSavedForTesting = { raise(SIGSTOP) }
        defer { FilesEngine.afterIntentSavedForTesting = nil }
        _ = try crashEngine.apply(crashEngine.preview(config), config: config)
        XCTFail("The child unexpectedly continued past the saved-intent barrier")
    }

    func testKilledProcessIntentBlocksReplayAfterRelaunch() throws {
        let source = try file("crash.txt", contents: "selected")
        let cfg = config([.copy(to: output.path)])
        try JSONEncoder().encode(cfg).write(to: root.appendingPathComponent("config.json"))
        XCTAssertEqual(try engine.preview(cfg).rows.first?.status, .ready)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
                           "FilesCoreTests.FilesEngineTests/testChildStopsAfterSavedIntent",
                           Bundle(for: FilesEngineTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PIP_FILES_CRASH_CHILD_ROOT"] = root.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }

        var observed: OperationRecord?
        var stopped = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var status: Int32 = 0
            let waited = waitpid(child.processIdentifier, &status, WUNTRACED | WNOHANG)
            if waited == child.processIdentifier, (status & 0xff) == 0x7f { stopped = true }
            if let files = try? fm.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let record = try? JSONDecoder().decode(OperationRecord.self, from: data),
                       record.state == .intent {
                        observed = record
                        break
                    }
                }
            }
            if (observed != nil && stopped) || !child.isRunning { break }
            usleep(20_000)
        }
        guard let observed else {
            XCTFail("Child did not persist an action intent within 10 seconds")
            return
        }
        XCTAssertTrue(stopped, "Child never reached the test-only SIGSTOP barrier")
        guard stopped else { return }
        XCTAssertEqual(observed.sourcePath, source.path)
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()

        let relaunched = FilesEngine(journalDirectory: journal)
        let recovered = try XCTUnwrap(relaunched.history().first)
        XCTAssertEqual(recovered.id, observed.id)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(try Data(contentsOf: source), Data("selected".utf8))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("crash.txt").path))
        let next = try relaunched.preview(cfg)
        XCTAssertNotEqual(next.rows.first?.status, .ready)
        XCTAssertTrue(try relaunched.apply(next, config: cfg).isEmpty)
    }
    #endif
}
