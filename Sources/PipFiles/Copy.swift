import Foundation
import FilesCore

/// Shared native copy mapping. System diagnostics stay in the local journal.
enum FileCopy {
    static let previewInstruction = "Review the proposed changes before choosing Apply. Applied actions are recorded in History."

    static func previewReason(_ row:PreviewRow)->String? {
        guard let issue = row.issue else {return nil}
        if row.status == .skipped {
            return row.ruleID == nil ? "No enabled rule matches this file." : "Already handled, or waiting for recovery. Check History before retrying."
        }
        if issue.contains("Partial download") || issue.contains("settling") || issue.contains("changed while") {
            return "The file is still settling. Preview again once it is complete."
        }
        if issue.contains("Symlink") || issue.contains("regular file") || issue.contains("symlink") {
            return "Only direct regular files are checked. Links and folders are kept."
        }
        if issue.contains("Destination") || issue.contains("destination") {
            return "The destination is occupied or conflicts with another action. Choose another name or folder."
        }
        if issue.contains("Invalid file name") || issue.contains("Unsafe path") {
            return "This name or path is not supported. Edit the rule, then preview again."
        }
        return "The file could not be checked safely. Check access in Finder, then preview again."
    }
    static let uncertain = "This action could not be confirmed. Inspect both paths in Finder before retrying."
}
