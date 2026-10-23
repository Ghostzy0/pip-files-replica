import Foundation
import Darwin
import CryptoKit

/// A synchronous, serialized engine. Call it from a background task in a UI.
/// It never starts watching folders or acts without an explicit `apply` call.
public final class FilesEngine: @unchecked Sendable {
    #if DEBUG
    static var afterIntentSavedForTesting: (() -> Void)?
    #endif
    private let journalDirectory: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private let stabilityWindow: TimeInterval = 3

    public init(journalDirectory: URL, fileManager: FileManager = .default) {
        self.journalDirectory = journalDirectory
        self.fileManager = fileManager
    }

    public func preview(_ config: FolderConfig) throws -> Preview {
        lock.lock(); defer { lock.unlock() }
        try validate(config)
        let folder = try safeURL(config.path, mustExist: true, directory: true)
        let records = try history()
        let children = try SafeFileOperations.directEntries(in: folder)
        let now = Date()
        var reserved = Set<String>()
        var rows: [PreviewRow] = []
        for (source, inspected) in children {
            let name = source.lastPathComponent
            var status: PreviewStatus = .skipped
            var issue: String?
            var fingerprint: FileFingerprint?
            var rule: Rule?
            var plan: [PlannedAction] = []
            var key: String?
            do {
                if isPartial(name) { throw FilesError.unstable("Partial download: \(name)") }
                fingerprint = try inspected.get()
                guard let fingerprint else { throw FilesError.unstable("Cannot read: \(name)") }
                if now.timeIntervalSince(fingerprint.modifiedAt) < stabilityWindow {
                    throw FilesError.unstable("File is still settling: \(name)")
                }
                rule = config.rules.first { $0.enabled && matches($0, name: name, fingerprint: fingerprint, now: now) }
                if let rule {
                    let signature = try ruleSignature(rule)
                    key = ledgerKey(config: config, rule: rule, signature: signature, source: source, fingerprint: fingerprint)
                    if records.contains(where: { ($0.state == .intent || $0.state == .interrupted || $0.state == .undoIntent) &&
                        ($0.sourcePath == source.path || $0.destinationPath == source.path) }) ||
                       records.contains(where: { $0.ledgerKey == key && ($0.state == .completed || $0.state == .intent || $0.state == .interrupted) }) ||
                       records.contains(where: { $0.state == .completed && $0.ruleSignature == nil &&
                           $0.ruleID == rule.id && $0.sourcePath == source.path && sameLegacyIdentity($0.before, fingerprint) }) ||
                       records.contains(where: { $0.state == .completed &&
                           ($0.after == fingerprint || ($0.ruleSignature == nil && sameLegacyIdentity($0.after, fingerprint))) &&
                           ($0.destinationPath == source.path || ($0.sourcePath == source.path && isTag($0.action) &&
                            $0.ruleID == rule.id && ($0.ruleSignature == nil || $0.ruleSignature == signature))) }) {
                        issue = "Already processed or needs recovery"
                    } else {
                        plan = try planActions(rule.actions, source: source)
                        let destinations = plan.compactMap(\.destinationPath)
                        if destinations.contains(where: { reserved.contains($0) }) {
                            throw FilesError.conflict("Two preview rows target the same destination")
                        }
                        reserved.formUnion(destinations)
                        status = .ready
                    }
                } else { issue = "No matching enabled rule" }
            } catch {
                status = .blocked
                issue = error.localizedDescription
            }
            rows.append(PreviewRow(id: UUID(), sourcePath: source.path, ruleID: rule?.id,
                                   ruleName: rule?.name, fingerprint: fingerprint, actions: plan,
                                   status: status, issue: issue, ledgerKey: key))
        }
        return Preview(folderID: config.id, configDigest: try digest(config), createdAt: now, rows: rows)
    }

    /// Fails closed if the config, source, planned destinations, or journal changed.
    /// Each action has its own durable intent/result record. A failed multi-action
    /// row is never retried automatically; inspect history and reconcile it first.
    @discardableResult
    public func apply(_ preview: Preview, config: FolderConfig) throws -> [OperationRecord] {
        lock.lock(); defer { lock.unlock() }
        let journalLock = try acquireJournalLock()
        defer { flock(journalLock, LOCK_UN); close(journalLock) }
        guard preview.folderID == config.id, preview.configDigest == (try digest(config)) else {
            throw FilesError.stalePreview("Rules or folder changed; preview again")
        }
        try validate(config)
        let current = try self.preview(config)
        let currentByPath = Dictionary(uniqueKeysWithValues: current.rows.map { ($0.sourcePath, $0) })
        for row in preview.rows where row.status == .ready {
            guard let fresh = currentByPath[row.sourcePath], fresh.status == .ready,
                  fresh.fingerprint == row.fingerprint, fresh.ruleID == row.ruleID,
                  fresh.actions == row.actions, fresh.ledgerKey == row.ledgerKey else {
                throw FilesError.stalePreview("Source or destination changed; preview again")
            }
        }
        var results: [OperationRecord] = []
        for row in preview.rows where row.status == .ready {
            guard let ruleID = row.ruleID, let key = row.ledgerKey,
                  let rule = config.rules.first(where: { $0.id == ruleID }) else { continue }
            let signature = try ruleSignature(rule)
            var currentSource = URL(fileURLWithPath: row.sourcePath)
            var expected = row.fingerprint
            for step in row.actions {
                // A prior action may change the path. Check the exact file again.
                let before = try fingerprintOf(currentSource)
                guard before == expected else { throw FilesError.stalePreview("Source changed during apply") }
                if let destination = step.destinationPath {
                    _ = try safeURL(URL(fileURLWithPath: destination).deletingLastPathComponent().path,
                                    mustExist: true, directory: true)
                    guard !fileManager.fileExists(atPath: destination) else {
                        throw FilesError.conflict("Destination already exists: \(destination)")
                    }
                }
                let previousTags = before.tags
                let previousTagMetadata: Data?
                if case .tag = step.action {
                    previousTagMetadata = try SafeFileOperations.tagMetadata(currentSource, expected: before)
                } else { previousTagMetadata = nil }
                var record = OperationRecord(id: UUID(), rowID: row.id, folderID: config.id, ruleID: ruleID,
                                             action: step.action, sourcePath: currentSource.path,
                                             destinationPath: step.destinationPath, before: before,
                                             after: nil, previousTags: previousTags, previousTagMetadata: previousTagMetadata,
                                             ledgerKey: key, ruleSignature: signature,
                                             createdAt: Date(), finishedAt: nil, state: .intent, issue: nil)
                if case .move = step.action {
                    record.stagingPath = reservedSibling(of: currentSource, prefix: ".pip-files-stage-").path
                } else if case .rename = step.action {
                    record.stagingPath = reservedSibling(of: currentSource, prefix: ".pip-files-stage-").path
                }
                try save(record)
                #if DEBUG
                Self.afterIntentSavedForTesting?()
                #endif
                do {
                    let postURL = try perform(step.action, source: currentSource, destination: step.destinationPath,
                                              staging: record.stagingPath, expected: before)
                    _ = try safeURL(postURL.path, mustExist: true, directory: false)
                    record.after = try fingerprintOf(postURL)
                    record.finishedAt = Date()
                    record.state = .completed
                    try save(record)
                    results.append(record)
                    switch step.action {
                    case .move, .rename, .tag:
                        currentSource = postURL
                        expected = record.after
                    case .copy, .zipArchive: break
                    }
                } catch {
                    // The write may have succeeded before a later error. Do not replay.
                    record.state = .interrupted
                    record.issue = error.localizedDescription
                    record.finishedAt = Date()
                    try? save(record)
                    throw error
                }
            }
        }
        return results
    }

    public func history() throws -> [OperationRecord] {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: journalDirectory.path) else { return [] }
        let files: [URL]
        do { files = try fileManager.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" } }
        catch { throw FilesError.journalCorrupt }
        do {
            return try files.map {
                var record = try JSONDecoder().decode(OperationRecord.self, from: Data(contentsOf: $0))
                if record.state == .intent || record.state == .undoIntent {
                    record.state = .interrupted
                    record.issue = "An action or undo may have been interrupted; inspect both paths manually"
                }
                return record
            }
                .sorted { $0.createdAt > $1.createdAt }
        } catch { throw FilesError.journalCorrupt }
    }

    @discardableResult
    public func undo(_ recordID: UUID) throws -> OperationRecord {
        lock.lock(); defer { lock.unlock() }
        let journalLock = try acquireJournalLock()
        defer { flock(journalLock, LOCK_UN); close(journalLock) }
        guard var record = try history().first(where: { $0.id == recordID }) else {
            throw FilesError.conflict("History record is missing")
        }
        guard record.state == .completed, let after = record.after else {
            throw FilesError.conflict("Only a completed, unchanged action can be undone")
        }
        let postPath = record.destinationPath ?? record.sourcePath
        let post = try safeURL(postPath, mustExist: true, directory: false)
        guard try fingerprintOf(post) == after else { throw FilesError.conflict("Result changed; undo refused") }
        let original = URL(fileURLWithPath: record.sourcePath)
        if case .move = record.action {
            _ = try safeURL(original.deletingLastPathComponent().path, mustExist: true, directory: true)
            guard !fileManager.fileExists(atPath: original.path) else {
                throw FilesError.conflict("Original path is occupied; undo refused")
            }
        }
        if case .rename = record.action {
            _ = try safeURL(original.deletingLastPathComponent().path, mustExist: true, directory: true)
            guard !fileManager.fileExists(atPath: original.path) else {
                throw FilesError.conflict("Original path is occupied; undo refused")
            }
        }
        record.state = .undoIntent
        switch record.action {
        case .copy, .zipArchive:
            record.recoveryPath = reservedSibling(of: post, prefix: ".pip-files-undo-").path
        case .move, .rename:
            record.undoStagingPath = reservedSibling(of: post, prefix: ".pip-files-stage-").path
        case .tag: break
        }
        try save(record)
        switch record.action {
        case .copy, .zipArchive:
            guard let recoveryPath = record.recoveryPath else { throw FilesError.journalCorrupt }
            try SafeFileOperations.retainForRecovery(post, at: URL(fileURLWithPath: recoveryPath), expected: after)
        case .move, .rename:
            guard let undoStagingPath = record.undoStagingPath else { throw FilesError.journalCorrupt }
            try SafeFileOperations.move(post, to: original, staging: URL(fileURLWithPath: undoStagingPath), expected: after)
        case .tag:
            try SafeFileOperations.restoreTagMetadata(post, metadata: record.previousTagMetadata, expected: after)
        }
        record.state = .undone
        record.finishedAt = Date()
        try save(record)
        return record
    }

    /// Undo a row in reverse order. Stops immediately if any result changed.
    @discardableResult
    public func undo(rowID: UUID) throws -> [OperationRecord] {
        lock.lock(); defer { lock.unlock() }
        return try history().filter { $0.rowID == rowID && $0.state == .completed }
            .sorted { $0.createdAt > $1.createdAt }.map { try undo($0.id) }
    }

    private func validate(_ config: FolderConfig) throws {
        _ = try safeURL(config.path, mustExist: true, directory: true)
        guard !config.name.isEmpty else { throw FilesError.invalidConfig("Folder needs a name") }
        guard Set(config.rules.map(\.id)).count == config.rules.count else {
            throw FilesError.invalidConfig("Duplicate rule IDs")
        }
        for rule in config.rules where rule.enabled {
            guard !rule.name.isEmpty, !rule.predicates.isEmpty, !rule.actions.isEmpty else {
                throw FilesError.invalidConfig("Enabled rules need a name, condition and action")
            }
            for predicate in rule.predicates {
                switch predicate {
                case .minimumSize(let x), .maximumSize(let x):
                    guard x >= 0 else { throw FilesError.invalidConfig("Size must be nonnegative") }
                case .minimumAge(let x), .maximumAge(let x):
                    guard x >= 0, x.isFinite else { throw FilesError.invalidConfig("Age must be finite and nonnegative") }
                case .nameContains(let x), .fileExtension(let x):
                    guard !x.isEmpty else { throw FilesError.invalidConfig("Text condition cannot be empty") }
                }
            }
        }
    }

    private func matches(_ rule: Rule, name: String, fingerprint: FileFingerprint, now: Date) -> Bool {
        let checks = rule.predicates.map { predicate -> Bool in
            switch predicate {
            case .nameContains(let text): return name.localizedCaseInsensitiveContains(text)
            case .fileExtension(let ext): return URL(fileURLWithPath: name).pathExtension.caseInsensitiveCompare(ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == .orderedSame
            case .minimumSize(let size): return fingerprint.size >= size
            case .maximumSize(let size): return fingerprint.size <= size
            case .minimumAge(let age): return now.timeIntervalSince(fingerprint.modifiedAt) >= age
            case .maximumAge(let age): return now.timeIntervalSince(fingerprint.modifiedAt) <= age
            }
        }
        return rule.match == .all ? checks.allSatisfy { $0 } : checks.contains(true)
    }

    private func planActions(_ actions: [FileAction], source: URL) throws -> [PlannedAction] {
        var current = source
        var steps: [PlannedAction] = []
        var reserved = Set<String>()
        for action in actions {
            let destination: URL?
            switch action {
            case .copy(let dir), .move(let dir), .zipArchive(let dir):
                let folder = try safeURL(dir, mustExist: true, directory: true)
                let name: String
                if case .zipArchive = action { name = current.lastPathComponent + ".zip" }
                else { name = current.lastPathComponent }
                destination = folder.appendingPathComponent(name)
            case .rename(let name):
                try validName(name)
                destination = current.deletingLastPathComponent().appendingPathComponent(name)
            case .tag(let tag):
                guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FilesError.invalidConfig("Tag cannot be blank")
                }
                destination = nil
            }
            if let destination {
                guard destination.path != current.path else { throw FilesError.conflict("Destination equals source") }
                guard !fileManager.fileExists(atPath: destination.path), !reserved.contains(destination.path) else {
                    throw FilesError.conflict("Destination exists or is repeated: \(destination.path)")
                }
                reserved.insert(destination.path)
            }
            steps.append(PlannedAction(action: action, sourcePath: current.path, destinationPath: destination?.path))
            if case .move = action, let destination { current = destination }
            if case .rename = action, let destination { current = destination }
        }
        return steps
    }

    private func perform(_ action: FileAction, source: URL, destination path: String?,
                         staging pathForStage: String?, expected: FileFingerprint) throws -> URL {
        let dest = path.map { URL(fileURLWithPath: $0) }
        switch action {
        case .copy:
            guard let dest else { throw FilesError.invalidConfig("Missing destination") }
            try SafeFileOperations.copy(source, to: dest, expected: expected)
            return dest
        case .move, .rename:
            guard let dest, let pathForStage else { throw FilesError.invalidConfig("Missing move destination or stage") }
            try SafeFileOperations.move(source, to: dest, staging: URL(fileURLWithPath: pathForStage), expected: expected)
            return dest
        case .tag(let tag):
            try SafeFileOperations.addTag(tag, to: source, expected: expected)
            return source
        case .zipArchive:
            guard let dest else { throw FilesError.invalidConfig("Missing destination") }
            try SafeFileOperations.archive(source, to: dest, expected: expected)
            return dest
        }
    }

    private func reservedSibling(of url: URL, prefix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(prefix + UUID().uuidString)
    }

    private func safeURL(_ path: String, mustExist: Bool, directory: Bool) throws -> URL {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains(".") else { throw FilesError.unsafePath("Unsafe path: \(path)") }
        // `standardizedFileURL` rewrites /private/var to /var on macOS, which
        // would introduce an apparent symlink and defeat the explicit check.
        let url = URL(fileURLWithPath: path)
        var check = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            check.appendPathComponent(part)
            if let values = try? check.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw FilesError.unsafePath("Symlink in path: \(check.path)")
            }
        }
        if mustExist {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  directory ? values.isDirectory == true : values.isRegularFile == true else {
                throw FilesError.unsafePath("Expected \(directory ? "directory" : "regular file"): \(path)")
            }
        }
        return url
    }

    private func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), !isPartial(name) else {
            throw FilesError.unsafePath("Invalid file name")
        }
    }

    private func isPartial(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".download") || lower.hasSuffix(".crdownload") ||
               lower.hasSuffix(".part") || lower.hasSuffix(".partial") ||
               lower.hasSuffix(".tmp") || lower.hasPrefix(".~") ||
               lower.hasPrefix(".pip-files-undo-") || lower.hasPrefix(".pip-files-stage-")
    }

    private func fingerprintOf(_ url: URL) throws -> FileFingerprint {
        try SafeFileOperations.fingerprint(url)
    }

    private func isTag(_ action: FileAction) -> Bool {
        if case .tag = action { return true }
        return false
    }

    private func sameLegacyIdentity(_ old: FileFingerprint?, _ current: FileFingerprint) -> Bool {
        guard let old else { return false }
        return old.deviceID == current.deviceID && old.fileID == current.fileID &&
               old.size == current.size && old.createdAt == current.createdAt &&
               old.modifiedAt == current.modifiedAt && old.tags == current.tags &&
               (old.permissions == nil || old.permissions == current.permissions)
    }

    private func digest(_ config: FolderConfig) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(config))
    }

    private func ruleSignature(_ rule: Rule) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var semanticRule = rule
        semanticRule.name = ""
        semanticRule.enabled = true
        return hash(try encoder.encode(semanticRule))
    }

    private func ledgerKey(config: FolderConfig, rule: Rule, signature: String, source: URL, fingerprint: FileFingerprint) -> String {
        let data = Data("\(config.id)|\(rule.id)|\(signature)|\(source.path)|\(fingerprint.deviceID)|\(fingerprint.fileID)|\(fingerprint.size)|\(fingerprint.permissions ?? 0)|\(fingerprint.createdAt.timeIntervalSince1970)|\(fingerprint.modifiedAt.timeIntervalSince1970)|\(fingerprint.contentHash)|\(fingerprint.tags.joined(separator: ","))".utf8)
        return hash(data)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ record: OperationRecord) throws {
        try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: journalDirectory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }

    private func acquireJournalLock() throws -> Int32 {
        try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        _ = try safeURL(journalDirectory.path, mustExist: true, directory: true)
        let path = journalDirectory.appendingPathComponent(".engine.lock").path
        let fd = path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw FilesError.unsafePath("Cannot safely open operation lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FilesError.conflict("Another Pip Files process is changing this journal")
        }
        return fd
    }
}
