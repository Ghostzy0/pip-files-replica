import XCTest
import Darwin
import FilesCore
@testable import PipFiles

@MainActor
final class AppStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let input: URL
        let output: URL
        let source: URL
        let config: FolderConfig
        let store: AppStore
    }

    private func fixture() throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.path
        let physical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        let root = URL(fileURLWithPath: physical).appendingPathComponent("PipFilesAppTests-\(UUID().uuidString)")
        let input = root.appendingPathComponent("Input")
        let output = root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = input.appendingPathComponent("receipt.txt")
        try Data("receipt".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: source.path)
        let rule = Rule(name: "Copy receipts", predicates: [.fileExtension("txt")], actions: [.copy(to: output.path)])
        let config = FolderConfig(name: "Input", path: input.path, rules: [rule])
        try JSONEncoder().encode([config]).write(to: root.appendingPathComponent("folders.json"))
        setenv("PIP_FILES_DATA_DIR", root.path, 1)
        defer { unsetenv("PIP_FILES_DATA_DIR") }
        let store = AppStore()
        XCTAssertTrue(store.storageHealthy)
        XCTAssertEqual(store.selected, config.id)
        return Fixture(root: root, input: input, output: output, source: source, config: config, store: store)
    }

    func testExtremeFiniteAgeCanBeEditedAndDescribedWithoutCrashing() {
        let value = Double.greatestFiniteMagnitude
        let condition = ConditionInput(.minimumAge(value))
        XCTAssertNotNil(condition.predicate)
        XCTAssertFalse(conditionName(.minimumAge(value)).isEmpty)
        XCTAssertFalse(conditionName(.maximumAge(value)).isEmpty)
    }

    func testEditionMarkerIsAuthoritativeAndUnbundledOverrideIsIsolated() {
        XCTAssertEqual(FeatureEdition.resolve(marker: "pip-plus", packaged: true, arguments: ["--baseline"]), .pipPlus)
        XCTAssertEqual(FeatureEdition.resolve(marker: "replica", packaged: true, arguments: ["--baseline", "--replica"]), .replica)
        XCTAssertNil(FeatureEdition.resolve(marker: "unknown", packaged: true, arguments: []))
        XCTAssertNil(FeatureEdition.resolve(marker: nil, packaged: true, arguments: ["--baseline"]))
        XCTAssertNil(FeatureEdition.resolve(marker: nil, packaged: true, arguments: ["--replica"]))
        XCTAssertEqual(FeatureEdition.resolve(marker: nil, packaged: false, arguments: ["app", "--baseline"]), .baseline)
        XCTAssertEqual(FeatureEdition.resolve(marker: nil, packaged: false, arguments: ["app", "--replica"]), .replica)
        XCTAssertEqual(FeatureEdition.resolve(marker: nil, packaged: false, arguments: ["app"]), .pip)
        XCTAssertNil(FeatureEdition.dataDirectoryOverride(environmentValue: "/tmp/redirect", packaged: true))
        XCTAssertEqual(FeatureEdition.dataDirectoryOverride(environmentValue: "/tmp/test-data", packaged: false)?.path,
                       "/tmp/test-data")
    }

    func testCanonicalFourAndLegacyEditionHaveUniqueIdentities() {
        let editions = FeatureEdition.allCases
        XCTAssertEqual(editions.count, 5)
        XCTAssertEqual(Set(editions.map(\.name)).count, 5)
        XCTAssertEqual(Set(editions.map(\.bundleIdentifier)).count, 5)
        XCTAssertEqual(Set(editions.map(\.rawValue)).count, 5)
        XCTAssertEqual(Set(editions.map { $0.dataDirectoryName(packaged: true) }).count, 5)
        XCTAssertEqual(Set(editions.map { $0.dataDirectoryName(packaged: false) }).count, 5)
        XCTAssertEqual(Set(editions.map(\.version)), ["0.1.0", "0.2.0"])
        XCTAssertEqual(Set(editions.map(\.baseline)), [false, true])
        XCTAssertEqual(Set(editions.map(\.enhanced)), [false, true])
        XCTAssertEqual(Set(FeatureEdition.releaseEditions), [.replica, .baselinePlus, .pip, .pipPlus])
        XCTAssertEqual(FeatureEdition.releaseEditions.count, 4)
        XCTAssertFalse(FeatureEdition.releaseEditions.contains(.baseline))
        XCTAssertEqual(FeatureEdition.releaseEditions.filter(\.referenceLayout).count, 2)
        XCTAssertTrue(FeatureEdition.replica.referenceLayout)
        XCTAssertTrue(FeatureEdition.baselinePlus.referenceLayout)
        XCTAssertFalse(FeatureEdition.pip.referenceLayout)
        XCTAssertFalse(FeatureEdition.pipPlus.referenceLayout)
    }

    func testAddFolderCommandCannotDiscardUnsavedReplicaRuleChanges() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalFolderCount = f.store.folders.count
        let originalSelection = f.store.selected
        f.store.hasUnsavedRuleChanges = true

        // The app-wide Cmd+O command calls addFolder() directly, bypassing view routing.
        f.store.addFolder()

        XCTAssertEqual(f.store.folders.count, originalFolderCount)
        XCTAssertEqual(f.store.selected, originalSelection)
        XCTAssertEqual(f.store.message, "Save or discard the unsaved rule before adding a folder.")
    }

    func testOpeningRuleEditorPausesWatchAndInvalidatesReviewedPlan() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.store.preview = try FilesEngine(journalDirectory: f.root.appendingPathComponent("Journal")).preview(f.config)
        XCTAssertEqual(f.store.preview?.rows.first?.status, .ready)
        f.store.watching = true

        f.store.editRule(f.config.rules[0])

        XCTAssertFalse(f.store.watching)
        XCTAssertNil(f.store.preview)
        XCTAssertEqual(f.store.editor?.rule.id, f.config.rules[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("receipt.txt").path))
    }

    func testManualPreviewPausesWatchAndLeavesFilesUnchanged() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.store.watching = true

        f.store.check()

        XCTAssertFalse(f.store.watching)
        // Allow the real asynchronous preview to finish, then prove it produced
        // a ready plan without invoking the automatic Apply path.
        for _ in 0..<200 where f.store.busy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(f.store.busy)
        XCTAssertEqual(f.store.preview?.rows.first?.status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("receipt.txt").path))
        XCTAssertTrue(f.store.records.isEmpty)
    }

    func testFailedConfigSaveDisablesCheckApplyUndoAndRejectsRuleDraft() throws {
        let f = try fixture()
        defer {
            _ = chmod(f.root.path, 0o700)
            try? FileManager.default.removeItem(at: f.root)
        }
        let plan = try FilesEngine(journalDirectory: f.root.appendingPathComponent("Journal")).preview(f.config)
        XCTAssertEqual(plan.rows.first?.status, .ready)
        f.store.watching = true

        XCTAssertEqual(chmod(f.root.path, 0o500), 0)
        var edited = f.config.rules[0]
        edited.name = "Updated rule"
        XCTAssertFalse(f.store.updateRule(edited))
        XCTAssertFalse(f.store.storageHealthy)
        XCTAssertFalse(f.store.watching)

        // Supply a real, previously reviewed plan to prove the unhealthy guard
        // blocks Apply rather than merely finding no plan.
        f.store.preview = plan
        f.store.check()
        f.store.apply()
        f.store.undo(UUID())
        XCTAssertFalse(f.store.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("receipt.txt").path))
        XCTAssertFalse(f.store.updateRule(edited))
    }

    func testCorruptHistoryReloadClearsStaleRowsAndFailsClosed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let engine = FilesEngine(journalDirectory: f.root.appendingPathComponent("Journal"))
        let plan = try engine.preview(f.config)
        let applied = try engine.apply(plan, config: f.config)
        XCTAssertEqual(applied.count, 1)
        f.store.reloadHistory()
        XCTAssertEqual(f.store.records.count, 1)
        XCTAssertTrue(f.store.storageHealthy)

        try Data("{".utf8).write(to: f.root.appendingPathComponent("Journal/broken.json"))
        f.store.watching = true
        f.store.reloadHistory()

        XCTAssertTrue(f.store.records.isEmpty)
        XCTAssertFalse(f.store.storageHealthy)
        XCTAssertFalse(f.store.watching)
        f.store.undo(applied[0].id)
        XCTAssertFalse(f.store.busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("receipt.txt").path))
    }
}
