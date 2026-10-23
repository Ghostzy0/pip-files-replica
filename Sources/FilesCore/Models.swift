import Foundation

public struct FolderConfig: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var rules: [Rule]

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil, rules: [Rule]) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark; self.rules = rules
    }
}

public enum MatchMode: String, Codable, Sendable { case all, any }

public struct Rule: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: MatchMode
    public var predicates: [Predicate]
    public var actions: [FileAction]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: MatchMode = .all,
                predicates: [Predicate], actions: [FileAction]) {
        self.id = id; self.name = name; self.enabled = enabled; self.match = match
        self.predicates = predicates; self.actions = actions
    }
}

public enum Predicate: Codable, Equatable, Sendable {
    case nameContains(String)
    case fileExtension(String)
    case minimumSize(Int64)
    case maximumSize(Int64)
    case minimumAge(TimeInterval)
    case maximumAge(TimeInterval)
}

public enum FileAction: Codable, Equatable, Sendable {
    case copy(to: String)
    case move(to: String)
    case rename(to: String)
    case tag(String)
    case zipArchive(to: String)
}

public enum PreviewStatus: String, Codable, Sendable { case ready, skipped, blocked }

public struct FileFingerprint: Codable, Equatable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64
    public let size: Int64
    public let permissions: UInt16?
    public let createdAt: Date
    public let modifiedAt: Date
    public let contentHash: String
    public let tags: [String]
}

public struct PlannedAction: Codable, Equatable, Sendable {
    public let action: FileAction
    public let sourcePath: String
    public let destinationPath: String?
}

public struct PreviewRow: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public let ruleID: UUID?
    public let ruleName: String?
    public let fingerprint: FileFingerprint?
    public let actions: [PlannedAction]
    public let status: PreviewStatus
    public let issue: String?
    public let ledgerKey: String?
}

public struct Preview: Codable, Sendable {
    public let folderID: UUID
    public let configDigest: String
    public let createdAt: Date
    public let rows: [PreviewRow]
}

public enum OperationState: String, Codable, Hashable, Sendable { case intent, completed, failed, interrupted, undoIntent, undone }

public struct OperationRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let rowID: UUID
    public let folderID: UUID
    public let ruleID: UUID
    public let action: FileAction
    public let sourcePath: String
    public let destinationPath: String?
    public let before: FileFingerprint
    public var after: FileFingerprint?
    public let previousTags: [String]?
    public let previousTagMetadata: Data?
    public let ledgerKey: String
    public let ruleSignature: String?
    /// Reserved before a move starts. If interrupted, inspect this same-parent path.
    public var stagingPath: String? = nil
    /// Reserved before undoing a move. Kept in the journal for interrupted undo.
    public var undoStagingPath: String? = nil
    /// Copy/ZIP undo retains its output here for manual recovery; it never unlinks it.
    public var recoveryPath: String? = nil
    public let createdAt: Date
    public var finishedAt: Date?
    public var state: OperationState
    public var issue: String?
}

public enum FilesError: Error, LocalizedError, Equatable {
    case invalidConfig(String)
    case unsafePath(String)
    case unstable(String)
    case stalePreview(String)
    case conflict(String)
    case journalCorrupt
    case interrupted(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let s), .unsafePath(let s), .unstable(let s), .stalePreview(let s),
             .conflict(let s), .interrupted(let s), .unsupported(let s): return s
        case .journalCorrupt: return "Journal is corrupt; file operations are disabled."
        }
    }
}
