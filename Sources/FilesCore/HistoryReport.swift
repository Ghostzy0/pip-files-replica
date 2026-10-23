import Foundation

public enum HistoryActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case copy, move, rename, tag, zipArchive

    public init(_ action: FileAction) {
        switch action {
        case .copy: self = .copy
        case .move: self = .move
        case .rename: self = .rename
        case .tag: self = .tag
        case .zipArchive: self = .zipArchive
        }
    }

    public var label: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .rename: return "Rename"
        case .tag: return "Tag"
        case .zipArchive: return "ZIP archive"
        }
    }
}

/// A read-only view of records already loaded from history(). `nil` set means
/// all states/actions; an empty set selects none. Input order is preserved.
public struct HistoryFilter: Sendable {
    public var searchText: String
    public var states: Set<OperationState>?
    public var actions: Set<HistoryActionKind>?
    public var createdFrom: Date?
    public var createdThrough: Date?

    public init(searchText: String = "", states: Set<OperationState>? = nil,
                actions: Set<HistoryActionKind>? = nil, createdFrom: Date? = nil,
                createdThrough: Date? = nil) {
        self.searchText = searchText
        self.states = states
        self.actions = actions
        self.createdFrom = createdFrom
        self.createdThrough = createdThrough
    }

    public func apply(to records: [OperationRecord]) -> [OperationRecord] {
        if let createdFrom, let createdThrough, createdFrom > createdThrough { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return records.filter { record in
            if let states, !states.contains(record.state) { return false }
            let kind = HistoryActionKind(record.action)
            if let actions, !actions.contains(kind) { return false }
            if let createdFrom, record.createdAt < createdFrom { return false }
            if let createdThrough, record.createdAt > createdThrough { return false }
            if !query.isEmpty {
                let haystack = [record.sourcePath, record.destinationPath ?? "", kind.label]
                    .joined(separator: "\n")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }
}

/// Versioned, explicit report allowlist. This is not a restorable journal.
public struct HistoryReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let records: [HistoryReportRow]

    public init(records: [OperationRecord]) {
        schemaVersion = 1
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.records = records.map { record in
            HistoryReportRow(operationID: record.id.uuidString, state: record.state.rawValue,
                             action: HistoryActionKind(record.action).label,
                             sourcePath: record.sourcePath, destinationPath: record.destinationPath,
                             createdAt: timestamp.string(from: record.createdAt),
                             finishedAt: record.finishedAt.map { timestamp.string(from: $0) },
                             issue: record.issue == nil ? nil :
                                 "This action could not be confirmed. Inspect source and result paths before retrying.")
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// UTF-8 RFC 4180 rows in the supplied order. A leading apostrophe is a
    /// spreadsheet formula mitigation, not a universal CSV safety guarantee.
    /// Use JSON when exact string values are required.
    public func csvData() -> Data {
        let header = ["operation_id", "state", "action", "source_path", "destination_path",
                      "created_at", "finished_at", "issue"]
        let lines = [header.joined(separator: ",")] + records.map { record in
            [record.operationID, record.state, record.action, record.sourcePath,
             record.destinationPath ?? "", record.createdAt, record.finishedAt ?? "", record.issue ?? ""]
                .map(Self.csvField).joined(separator: ",")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func csvField(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let leadingIgnorables = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{FEFF}"))
        let leading = scalars.first
        let firstVisible = scalars.first { !leadingIgnorables.contains($0) }
        let formulaScalars = CharacterSet(charactersIn: "=+-@＝＋－＠")
        let suspicious = leading.map { leadingIgnorables.contains($0) } == true ||
            firstVisible.map { formulaScalars.contains($0) } == true
        let guarded = suspicious ? "'" + value : value
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public struct HistoryReportRow: Codable, Equatable, Sendable {
    public let operationID: String
    public let state: String
    public let action: String
    public let sourcePath: String
    public let destinationPath: String?
    public let createdAt: String
    public let finishedAt: String?
    public let issue: String?
}
