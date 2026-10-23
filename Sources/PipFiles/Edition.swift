import Foundation

/// Presentation and optional reports share the same file-operation engine.
enum FeatureEdition: String, CaseIterable {
    case baseline, baselinePlus = "baseline-plus", pip, pipPlus = "pip-plus", replica

    /// Canonical editions in the split release set. `baseline` remains a reproducible
    /// legacy generic workflow package, not the Hazel-style neutral edition.
    static let releaseEditions: [Self] = [.replica, .baselinePlus, .pip, .pipPlus]

    static func resolve(marker: String?, packaged: Bool, arguments: [String]) -> Self? {
        if let marker { return Self(rawValue: marker) }
        guard !packaged else { return nil }
        if arguments.contains("--replica") { return .replica }
        return arguments.contains("--baseline") ? .baseline : .pip
    }
    static var packaged: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var selected: Self? {
        resolve(marker: Bundle.main.object(forInfoDictionaryKey: "PipFilesEdition") as? String,
                packaged: packaged, arguments: ProcessInfo.processInfo.arguments)
    }
    // Invalid packages may render recovery text, but AppStore refuses to open data.
    static var current: Self { selected ?? .pip }
    static var dataDirectoryName: String {
        guard let selected else { return "Pip Files Invalid Configuration" }
        return selected.dataDirectoryName(packaged: packaged)
    }
    static func dataDirectoryOverride(environmentValue: String?, packaged: Bool) -> URL? {
        guard !packaged, let environmentValue, !environmentValue.isEmpty else { return nil }
        return URL(fileURLWithPath: environmentValue)
    }
    func dataDirectoryName(packaged: Bool) -> String { packaged ? name : name + " Development" }
    var baseline: Bool { self == .baseline || self == .baselinePlus }
    var referenceLayout: Bool { self == .replica || self == .baselinePlus }
    var enhanced: Bool { self == .baselinePlus || self == .pipPlus }
    var name: String {
        switch self {
        case .baseline: return "Files Baseline"
        case .baselinePlus: return "Files Baseline Plus"
        case .pip: return "Pip Files"
        case .pipPlus: return "Pip Files Plus"
        case .replica: return "Files Replica"
        }
    }
    var version: String { enhanced ? "0.2.0" : "0.1.0" }
    var bundleIdentifier: String { "com.pipreps.files.\(rawValue)" }
}
