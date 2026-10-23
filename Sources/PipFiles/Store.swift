import AppKit
import SwiftUI
import FilesCore

@MainActor final class AppStore: ObservableObject {
    @Published var storageHealthy = false
    @Published var folders: [FolderConfig] = []
    @Published var selected: UUID?
    @Published var preview: FilesCore.Preview?
    @Published var records: [OperationRecord] = []
    @Published var busy = false
    @Published var message = "Choose a folder to begin. Nothing runs automatically."
    @Published var watching = false
    @Published var showHistory = false
    @Published var editor: RuleDraft?
    @Published var hasUnsavedRuleChanges = false
    let root: URL
    private var engine: FilesEngine!
    private let worker = DispatchQueue(label: "com.pipreps.files.engine", qos: .userInitiated)
    private var timer: Timer?
    private var access: [URL] = []
    private var destinationGrants: [String:Data] = [:]
    private var backgroundChecking = false
    private var signatures: [UUID: Data] = [:]
    var current: FolderConfig? { folders.first { $0.id == selected } }
    var configURL: URL { root.appendingPathComponent("folders.json") }

    init() {
        let custom = FeatureEdition.dataDirectoryOverride(
            environmentValue: ProcessInfo.processInfo.environment["PIP_FILES_DATA_DIR"],
            packaged: FeatureEdition.packaged)
        let editionName = FeatureEdition.dataDirectoryName
        root = custom ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(editionName)
        guard FeatureEdition.selected != nil else {
            message = "This package has an invalid edition marker. Open a verified package. Saved rules were not opened."
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            engine = FilesEngine(journalDirectory: root.appendingPathComponent("Journal"))
            if FileManager.default.fileExists(atPath: configURL.path) {
                folders = try JSONDecoder().decode([FolderConfig].self, from: Data(contentsOf: configURL))
                for i in folders.indices {
                    if let data = folders[i].bookmark {
                        var stale = false
                        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                        if url.startAccessingSecurityScopedResource() { access.append(url) }
                        folders[i].path = url.path
                    }
                }
            }
            let grantsURL = root.appendingPathComponent("destination-grants.json")
            if FileManager.default.fileExists(atPath:grantsURL.path) {
                destinationGrants = try JSONDecoder().decode([String:Data].self,from:Data(contentsOf:grantsURL))
                for data in destinationGrants.values {
                    var stale = false
                    let url = try URL(resolvingBookmarkData:data,options:.withSecurityScope,bookmarkDataIsStale:&stale)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                }
            }
            selected = folders.first?.id
            records = try engine.history()
            storageHealthy = true
            message = folders.isEmpty ? "Choose a folder to begin. Nothing runs automatically." : "Ready. Background rules are paused."
        } catch { message = "Saved data could not be opened. Keep your data and check its location in Finder." }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }
    func save() {
        guard storageHealthy else { return }
        do { try JSONEncoder().encode(folders).write(to: configURL, options: .atomic) }
        catch { watching = false; storageHealthy = false; message = "Changes could not be saved. File operations are disabled. Reopen the app to restore saved rules." }
        preview = nil; signatures.removeAll()
    }
    func addFolder(sample: Bool = false) {
        guard !hasUnsavedRuleChanges else {
            message = "Save or discard the unsaved rule before adding a folder."
            return
        }
        guard !busy, storageHealthy else { return }
        watching = false; preview = nil; signatures.removeAll()
        if sample {
            do {
                let base = root.appendingPathComponent("Sample Workspace", isDirectory: true)
                let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
                let destination = base.appendingPathComponent("Filed", isDirectory: true)
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let file = inbox.appendingPathComponent("sample-receipt.txt")
                if !FileManager.default.fileExists(atPath: file.path) { try Data("Sample receipt\nTotal: GBP 12.50\n".utf8).write(to: file) }
                try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-30)], ofItemAtPath:file.path)
                if let existing = folders.first(where: { $0.path == inbox.path }) { selected = existing.id; return }
                let rule = Rule(name: "File sample receipts", match: .all, predicates: [.fileExtension("txt")], actions: [.move(to: destination.path)])
                let folder = FolderConfig(name: "Sample Inbox", path: inbox.path, rules: [rule])
                folders.append(folder); selected = folder.id; save()
                guard storageHealthy else {return}
                message = "Sample folder created. Preview the receipt before applying."
            } catch { message = "The sample folder could not be created. Choose another folder." }
            return
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose folder"; panel.message = "Only files directly inside this folder will be checked. Rules stay paused."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = folders.first(where: {$0.path == url.path}) { selected = existing.id; return }
        if url.startAccessingSecurityScopedResource() { access.append(url) }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = FolderConfig(name:url.lastPathComponent, path:url.path, bookmark:bookmark, rules:[])
        folders.append(folder); selected = folder.id; save(); guard storageHealthy else {return}; message = "Folder added. Add a rule, then preview."
    }
    func chooseDestination() -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.startAccessingSecurityScopedResource() { access.append(url) }
        do {
            destinationGrants[url.path] = try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            try JSONEncoder().encode(destinationGrants).write(to:root.appendingPathComponent("destination-grants.json"),options:.atomic)
        } catch {message = "Destination access could not be saved. Choose the folder again after reopening.";return nil}
        return url.path
    }
    func editRule(_ rule: Rule? = nil) {
        guard !busy, storageHealthy else {return}
        watching = false; preview = nil; signatures.removeAll()
        editor = rule.map(RuleDraft.init) ?? RuleDraft()
        message = "Background rules paused while editing."
    }
    @discardableResult func updateRule(_ rule: Rule) -> Bool {
        guard let i = folders.firstIndex(where: {$0.id == selected}), !busy, storageHealthy else { return false }
        if let j = folders[i].rules.firstIndex(where: {$0.id == rule.id}) { folders[i].rules[j] = rule }
        else { folders[i].rules.append(rule) }
        watching = false; save(); guard storageHealthy else {return false}; editor = nil; message = "Rule saved. Preview to check what will change.";return true
    }
    func removeRule(_ id: UUID) { guard let i = folders.firstIndex(where: {$0.id == selected}), !busy, storageHealthy else { return }; folders[i].rules.removeAll {$0.id == id}; watching = false; save() }
    func moveRule(_ id: UUID, _ delta: Int) {
        guard let i = folders.firstIndex(where: {$0.id == selected}), let j = folders[i].rules.firstIndex(where: {$0.id == id}), folders[i].rules.indices.contains(j + delta), !busy, storageHealthy else { return }
        folders[i].rules.swapAt(j,j+delta); watching = false; save()
    }
    func toggleRule(_ id: UUID) {
        guard let i = folders.firstIndex(where: {$0.id == selected}), let j = folders[i].rules.firstIndex(where: {$0.id == id}), !busy, storageHealthy else { return }
        folders[i].rules[j].enabled.toggle(); watching = false; save()
    }
    func removeFolder() {
        guard !busy, storageHealthy else { return }; watching = false
        folders.removeAll {$0.id == selected}; selected = folders.first?.id; save()
        guard storageHealthy else {return}
        message = "Folder removed from Pip Files. Its files were kept."
    }
    func check() {
        guard let folder = current, !busy, storageHealthy, engine != nil else { return }
        // A manual review must not overlap automatic mutations. In-flight
        // background observations recheck watching before they can apply.
        watching = false; signatures.removeAll()
        busy = true; message = "Checking files. Nothing is being changed."
        worker.async { [self, engine = engine!] in
            do { let result = try engine.preview(folder); Task { @MainActor in if self.selected == folder.id { self.preview = result }; self.busy = false; self.message = "Preview ready. Review every change before applying." } }
            catch { Task { @MainActor in self.busy = false; self.preview = nil; self.message = "The folder could not be checked. Reconnect it or choose it again." } }
        }
    }
    func apply() {
        guard let folder = current, let plan = preview, !busy, storageHealthy, engine != nil else { return }
        busy = true; preview = nil; message = "Applying the reviewed changes."
        worker.async { [self, engine = engine!] in
            do { let result = try engine.apply(plan, config: folder); let history = try engine.history(); Task { @MainActor in self.records = history; self.busy = false; self.message = result.isEmpty ? "No changes applied. Preview again to check the current files." : (result.count == 1 ? "Applied 1 action. Review History or Undo." : "Applied \(result.count) actions. Review History or Undo.") } }
            catch { Task { @MainActor in self.busy = false; self.watching = false; self.message = "The run could not finish. Check History, then create a fresh preview."; self.reloadHistory() } }
        }
    }
    func reloadHistory() { guard engine != nil, storageHealthy else {return}; do { records = try engine.history() } catch {records = []; storageHealthy = false; watching = false; message = "History could not be read. File operations are disabled. Keep the saved journal for recovery."} }
    func undo(_ id: UUID) {
        guard !busy, storageHealthy, engine != nil else { return }; busy = true; watching = false
        worker.async { [self, engine = engine!] in
            do { _ = try engine.undo(id); let history = try engine.history(); Task { @MainActor in self.records = history; self.busy = false; self.preview = nil; self.message = "Operation undone." } }
            catch { Task { @MainActor in self.busy = false; self.message = "Undo was refused. Inspect the source and result paths in History, then check the file in Finder."; self.reloadHistory() } }
        }
    }
    func enableBackground() {
        guard !busy, storageHealthy, editor == nil, current != nil else {return}
        signatures.removeAll(); preview = nil; watching = true
        message = "Background rules enabled for the selected folder."
    }
    func pauseBackground() {
        watching = false; signatures.removeAll()
        message = busy ? "Background rules paused. The current action may finish." : "Background rules paused."
    }
    func poll() {
        guard watching, !busy, !backgroundChecking, let folder = current, engine != nil else { return }
        backgroundChecking = true
        worker.async { [self, engine = engine!] in
            do {
                let plan = try engine.preview(folder)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let signature = try encoder.encode(plan.rows.map { StableObservation(source:$0.sourcePath, rule:$0.ruleID, fingerprint:$0.fingerprint, status:$0.status.rawValue, actions:$0.actions) })
                Task { @MainActor in
                    self.backgroundChecking = false
                    guard self.watching, !self.busy, self.current == folder, self.editor == nil, !self.showHistory else {return}
                    if self.signatures[folder.id] == signature, plan.rows.contains(where: {$0.status == .ready}) {
                        self.preview = plan; self.apply()
                    } else { self.signatures[folder.id] = signature }
                }
            } catch { Task { @MainActor in self.backgroundChecking = false; if self.watching, self.current == folder {self.watching = false; self.message = "Background rules paused. The folder could not be checked."} } }
        }
    }
}

struct RuleDraft: Identifiable {
    var id: UUID = UUID()
    var rule: Rule
    init(_ rule: Rule = Rule(name:"New rule", match:.all, predicates:[.fileExtension("pdf")], actions:[])) { self.rule = rule }
}

private struct StableObservation: Codable { let source:String; let rule:UUID?; let fingerprint:FileFingerprint?; let status:String; let actions:[PlannedAction] }
