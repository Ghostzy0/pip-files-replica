import AppKit
import Darwin
import FilesCore
import SwiftUI
import UniformTypeIdentifiers

/// The Plus editions use the same read-only controls in both native appearances.
/// Filters never change the journal or the undo eligibility of its full history.
struct EnhancedHistory: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("pip.files.theme") private var look = "paper"
    @AppStorage("pip.files.appearance") private var appearance = "light"
    @State private var searchText = ""
    @State private var stateChoice = "all"
    @State private var actionChoice = "all"
    @State private var pendingExport: HistoryExportSnapshot?

    private let states: [OperationState] = [.completed, .undone, .failed, .interrupted, .intent, .undoIntent]

    private var filter: HistoryFilter {
        HistoryFilter(searchText: searchText,
                      states: OperationState(rawValue: stateChoice).map {Set([$0])},
                      actions: HistoryActionKind(rawValue: actionChoice).map {Set([$0])})
    }

    private var visibleRecords: [OperationRecord] { filter.apply(to: store.records) }
    private var palette: PipPalette { PipPalette(dark: appearance == "dark", oat: look == "oat") }
    private var hasFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        stateChoice != "all" || actionChoice != "all"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PipSpace.card) {
            HStack(alignment: .center, spacing: PipSpace.row) {
                TextField("Search filename, action or path", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search history by filename, action or path")
                Picker("State", selection: $stateChoice) {
                    Text("All states").tag("all")
                    ForEach(states, id: \.self) { state in
                        Text(Self.label(for: state)).tag(state.rawValue)
                    }
                }.frame(width: 155)
                Picker("Action", selection: $actionChoice) {
                    Text("All actions").tag("all")
                    ForEach(HistoryActionKind.allCases, id: \.self) { action in
                        Text(action.label).tag(action.rawValue)
                    }
                }.frame(width: 155)
            }
            HStack(spacing: PipSpace.row) {
                Text(countText).foregroundStyle(.secondary)
                    .accessibilityLabel("Showing \(visibleRecords.count) of \(store.records.count) history actions")
                Button("Reset filters") { reset() }.disabled(!hasFilters)
                Spacer(minLength: 0)
                Button("Export report…") { prepareExport() }
                    .disabled(store.busy || !store.storageHealthy)
            }.font(.callout)
            HistoryRows(records: visibleRecords,
                        emptyMessage: emptyMessage)
        }
        .sheet(item: $pendingExport) { snapshot in
            HistoryExportConfirmation(snapshot: snapshot, protectedRoot: store.root)
                .environmentObject(store)
                .tint(palette.ink)
                .background(palette.canvas)
                .preferredColorScheme(appearance == "dark" ? .dark : .light)
        }
    }

    private var countText: String {
        let shown = visibleRecords.count
        let total = store.records.count
        return "\(shown) of \(total) \(total == 1 ? "action" : "actions")"
    }

    private var emptyMessage: String {
        if !store.storageHealthy {
            return "History is unavailable. Saved records are kept. Reopen after checking the data folder."
        }
        if !store.records.isEmpty && hasFilters {
            return "No actions match these filters. Reset them to see all History."
        }
        return "No operations yet. Applied changes and recovery details appear here."
    }

    private func reset() {
        searchText = ""
        stateChoice = "all"
        actionChoice = "all"
    }

    private func prepareExport() {
        guard !store.busy, store.storageHealthy else { return }
        // Copy the filtered set now. Later undo or filter edits cannot change the report
        // awaiting confirmation and the save panel.
        let frozen = visibleRecords
        let scope = [
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Search: \(searchText.trimmingCharacters(in: .whitespacesAndNewlines))",
            stateChoice == "all" ? nil : "State: \(Self.label(for: OperationState(rawValue: stateChoice) ?? .completed))",
            actionChoice == "all" ? nil : "Action: \(HistoryActionKind(rawValue: actionChoice)?.label ?? "All")"
        ].compactMap {$0}.joined(separator: " · ")
        pendingExport = HistoryExportSnapshot(report: HistoryReport(records: frozen),
                                              count: frozen.count,
                                              scope: scope.isEmpty ? "All History" : scope,
                                              capturedAt: Date())
    }

    private static func label(for state: OperationState) -> String {
        switch state {
        case .intent: return "Pending"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .undoIntent: return "Undo pending"
        case .undone: return "Undone"
        }
    }
}

private struct HistoryExportSnapshot: Identifiable {
    let id = UUID()
    let report: HistoryReport
    let count: Int
    let scope: String
    let capturedAt: Date
}

private enum HistoryExportFormat {
    case json, csv

    var contentType: UTType { self == .json ? .json : .commaSeparatedText }
    var fileExtension: String { self == .json ? "json" : "csv" }
}

private struct HistoryExportConfirmation: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pip.files.theme") private var look = "paper"
    @AppStorage("pip.files.appearance") private var appearance = "light"
    @State private var errorText = ""
    let snapshot: HistoryExportSnapshot
    let protectedRoot: URL
    private var palette: PipPalette { PipPalette(dark: appearance == "dark", oat: look == "oat") }

    var body: some View {
        VStack(alignment: .leading, spacing: PipSpace.card) {
            Text("Export History report").font(.title2.weight(.semibold))
            Text("\(snapshot.count) \(snapshot.count == 1 ? "action" : "actions") from \(snapshot.scope).")
                .textSelection(.enabled)
            Text("Captured \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)). The report includes source and destination paths, which may reveal private folder names.")
                .foregroundStyle(.secondary)
            Text("This is a report for review, not a backup you can restore. JSON keeps exact values and is recommended. CSV is for spreadsheets; spreadsheet formula protection is not universal.")
                .foregroundStyle(.secondary)
            Text("An empty result exports a report with no actions. Existing files cannot be replaced.")
                .font(.callout).foregroundStyle(.secondary)
            if !errorText.isEmpty {
                Text(errorText).foregroundStyle(palette.danger).accessibilityAddTraits(.isStaticText)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save CSV…") { save(.csv) }
                Button("Save JSON…") { save(.json) }
                    .buttonStyle(PipPrimaryStyle(palette: palette)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(PipSpace.section).frame(width: 540)
    }

    private func save(_ format: HistoryExportFormat) {
        errorText = ""
        let data: Data
        do {
            data = format == .json ? try snapshot.report.jsonData() : snapshot.report.csvData()
        } catch {
            errorText = "The report could not be prepared. Nothing was saved."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "pip-files-history.\(format.fileExtension)"
        panel.message = "Save a local report. Existing files will not be replaced."
        panel.prompt = "Save report"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try HistoryExclusiveWriter.save(data, to: destination, outside: protectedRoot)
            store.message = "History report saved locally. Saved rules and History were not changed."
            dismiss()
        } catch HistoryExclusiveWriter.ExportError.existingFile {
            errorText = "A file already exists there. Choose another name to keep both files."
        } catch HistoryExclusiveWriter.ExportError.protectedLocation {
            errorText = "Choose a folder outside Pip Files saved data. No report was written."
        } catch HistoryExclusiveWriter.ExportError.linkedLocation {
            errorText = "Choose a folder without a linked path. No report was written."
        } catch HistoryExclusiveWriter.ExportError.partialFile(let path) {
            errorText = "The report could not finish. A partial file remains at \(path). Review or remove it in Finder before trying another name."
        } catch {
            errorText = "The report could not be saved. Choose another folder and try again. History was not changed."
        }
    }
}

/// Exclusive creation relative to a pinned directory prevents the save panel
/// from replacing any existing source or journal file. No cleanup unlinks paths:
/// a partial report remains visible if writing fails.
enum HistoryExclusiveWriter {
    enum ExportError: Error { case existingFile, protectedLocation, linkedLocation, partialFile(String), writeFailed }

    static func save(_ data: Data, to chosenURL: URL, outside rootURL: URL,
                     failAfterBytesForTesting: Int? = nil) throws {
        let root = try canonicalFilesystemPath(rootURL.standardizedFileURL.path)
        let selectedParent = try canonicalFilesystemPath(
            chosenURL.deletingLastPathComponent().standardizedFileURL.path)
        let name = chosenURL.lastPathComponent
        guard !name.isEmpty && name != "." && name != ".." && !name.contains("/") else {
            throw ExportError.writeFailed
        }
        // Resolve the selected folder, check the protected data boundary, then
        // reopen every path component with O_NOFOLLOW so a linked ancestor
        // cannot redirect the save between canonicalization and file creation.
        let pinnedParent = selectedParent
        guard root != "/" && pinnedParent != root && !pinnedParent.hasPrefix(root + "/") else {
            throw ExportError.protectedLocation
        }
        let rootFD = try openDirectoryWithoutLinkedComponents(root)
        defer { _ = Darwin.close(rootFD) }
        let rootIdentity = try directoryIdentity(rootFD)
        let directoryFD = try openDirectoryWithoutLinkedComponents(pinnedParent,
                                                                    forbidding: rootIdentity)
        defer { _ = Darwin.close(directoryFD) }
        let target = URL(fileURLWithPath: pinnedParent).appendingPathComponent(name).path
        let fd = Darwin.openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            if errno == EEXIST { throw ExportError.existingFile }
            if errno == ELOOP { throw ExportError.linkedLocation }
            throw ExportError.writeFailed
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(fd) }
        }
        let wroteAll = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                // Fault injection verifies that an incomplete report is retained.
                // Normal exports always write the full remaining buffer.
                if let limit = failAfterBytesForTesting, offset >= limit { return false }
                let length = failAfterBytesForTesting.map { min(bytes.count - offset, $0 - offset) }
                    ?? (bytes.count - offset)
                let written = Darwin.write(fd, base.advanced(by: offset), length)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, Darwin.fsync(fd) == 0 else { throw ExportError.partialFile(target) }
        let closed = Darwin.close(fd) == 0
        descriptorOpen = false
        guard closed else { throw ExportError.partialFile(target) }
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw ExportError.writeFailed }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func openDirectoryWithoutLinkedComponents(
        _ path: String,
        forbidding protectedIdentity: DirectoryIdentity? = nil
    ) throws -> Int32 {
        guard path.hasPrefix("/") else { throw ExportError.writeFailed }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExportError.writeFailed }
        if let protectedIdentity, try directoryIdentity(descriptor) == protectedIdentity {
            _ = Darwin.close(descriptor)
            throw ExportError.protectedLocation
        }
        for component in path.split(separator: "/") {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let error = errno
                _ = Darwin.close(descriptor)
                if error == ELOOP { throw ExportError.linkedLocation }
                throw ExportError.writeFailed
            }
            if let protectedIdentity {
                let identity: DirectoryIdentity
                do { identity = try directoryIdentity(next) }
                catch {
                    _ = Darwin.close(next)
                    _ = Darwin.close(descriptor)
                    throw error
                }
                if identity == protectedIdentity {
                    _ = Darwin.close(next)
                    _ = Darwin.close(descriptor)
                    throw ExportError.protectedLocation
                }
            }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    /// POSIX realpath returns the filesystem's canonical spelling as well as
    /// resolving links. Foundation's URL spelling alone preserves APFS case
    /// aliases, which can bypass a case-sensitive string-prefix boundary check.
    private static func canonicalFilesystemPath(_ path: String) throws -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { source in
            resolved.withUnsafeMutableBufferPointer { buffer in
                Darwin.realpath(source, buffer.baseAddress)
            }
        }
        guard result != nil else { throw ExportError.writeFailed }
        return String(cString: resolved)
    }
}
