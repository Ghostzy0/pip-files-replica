import SwiftUI
import AppKit
import FilesCore

/// Original native implementation of the documented folder → rule → editor workflow.
/// No vendor resources, source, or branding are used by this view.
struct HazelReplicaView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedRule: UUID?
    @State private var dirty = false
    @State private var pendingRoute: Route?
    @State private var discardConsent = false
    @State private var watchConsent = false
    @State private var removeConsent = false
    @State private var showStatus = false
    @State private var statusMode: ReplicaRuleStatus.Mode = .preview
    @State private var ruleSearch = ""

    private enum Route { case folder(UUID), rule(Rule), newRule, history, addFolder, sample }
    private var editable: Bool { !store.busy && store.storageHealthy }
    private var rules: [Rule] { (store.current?.rules ?? []).filter {ruleSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(ruleSearch)} }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                folders.frame(minWidth: 170, idealWidth: 200, maxWidth: 300)
                ruleList.frame(minWidth: 190, idealWidth: 220, maxWidth: 320)
                editor.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: store.watching ? "play.circle" : "pause.circle").accessibilityHidden(true)
                Text(store.message).textSelection(.enabled)
                Spacer(minLength: 0)
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.watching ? "Running" : "Paused").foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Discard unsaved rule changes?", isPresented: $discardConsent) {
            Button("Discard changes", role: .destructive) { if let route = pendingRoute { perform(route) }; pendingRoute = nil }
            Button("Keep editing", role: .cancel) { pendingRoute = nil }
        } message: { Text("Your saved rule will be kept.") }
        .confirmationDialog("Run rules for this selected folder while the app stays open?", isPresented: $watchConsent) {
            Button("Resume rules") { store.enableBackground() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only direct stable files are checked. Rules may move, rename, copy, tag or archive files. Every launch starts paused.") }
        .confirmationDialog("Remove the selected folder?", isPresented: $removeConsent) {
            Button("Remove folder", role: .destructive) { store.editor = nil; selectedRule = nil; store.removeFolder() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only its saved rules are removed. Its files are kept.") }
        .sheet(isPresented: $showStatus) {
            ReplicaRuleStatus(mode: statusMode, refresh: refreshStatus).environmentObject(store)
        }
        .onChange(of: store.selected) { _, _ in selectedRule = nil; store.editor = nil; dirty = false; store.hasUnsavedRuleChanges = false; ruleSearch = "" }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            tool("Add folder", icon: "folder.badge.plus") { navigate(.addFolder) }
            Menu {
                Button("Create sample folder") { navigate(.sample) }
                Button("Reveal folder in Finder") { if let folder = store.current { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) } }.disabled(store.current == nil)
                Divider()
                Button("Remove folder…", role: .destructive) { removeConsent = true }.disabled(store.current == nil || dirty)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel("Folder actions").disabled(!editable)
            Divider().frame(height: 24)
            tool("New rule", icon: "list.bullet.rectangle.badge.plus", disabled: store.current == nil) { navigate(.newRule) }
            tool("Rule status", icon: "waveform.path.ecg", disabled: store.current == nil || dirty) { openStatus(.ruleStatus) }
            tool(store.watching ? "Pause rules" : "Resume rules…", icon: store.watching ? "pause.fill" : "play.fill", disabled: dirty || store.current?.rules.isEmpty != false) {
                if store.watching { store.pauseBackground() } else { store.editor = nil; watchConsent = true }
            }
            Divider().frame(height: 24)
            tool("Preview changes", icon: "eye", disabled: store.current == nil || dirty) { openStatus(.preview) }
            Spacer(minLength: 8)
            Button { navigate(.history) } label: { Label("History", systemImage: "clock.arrow.circlepath") }.disabled(store.busy)
        }.padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
    }

    private func tool(_ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 17)).frame(width: 30, height: 26) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title).disabled(disabled || !editable)
    }

    private var folders: some View {
        VStack(spacing: 0) {
            columnHeading("Folders")
            List(selection: Binding(get: {store.selected}, set: {if let id = $0 {navigate(.folder(id))}})) {
                ForEach(store.folders, id: \.id) { folder in
                    Label(folder.name, systemImage: "folder.fill").tag(folder.id).help(folder.path)
                }
            }.listStyle(.sidebar).disabled(store.busy)
            if store.folders.isEmpty {
                Text("Choose a folder to add rules. Nothing runs automatically.").foregroundStyle(.secondary).padding(12)
                Button("Choose folder…") { navigate(.addFolder) }.padding(.bottom, 12).disabled(!editable)
            }
        }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            columnHeading("Rules")
            TextField("Search rules", text: $ruleSearch).textFieldStyle(.roundedBorder).padding(8).accessibilityLabel("Search rules")
            List(selection: Binding(get: {selectedRule}, set: { id in if let rule = store.current?.rules.first(where: {$0.id == id}) {navigate(.rule(rule))} })) {
                ForEach(rules, id: \.id) { rule in
                    HStack(spacing: 8) {
                        Toggle("Enable \(rule.name)", isOn: Binding(get: {rule.enabled}, set: {_ in store.toggleRule(rule.id)})).toggleStyle(.checkbox).labelsHidden().disabled(!editable || dirty)
                        Text(rule.name).lineLimit(2)
                    }.tag(rule.id).contextMenu {
                        Button("Edit rule") { navigate(.rule(rule)) }
                        Button("Move up") { store.moveRule(rule.id, -1) }.disabled(dirty || store.current?.rules.first?.id == rule.id)
                        Button("Move down") { store.moveRule(rule.id, 1) }.disabled(dirty || store.current?.rules.last?.id == rule.id)
                        Divider()
                        Button("Remove rule", role: .destructive) { if selectedRule == rule.id {store.editor = nil; selectedRule = nil}; store.removeRule(rule.id) }.disabled(dirty)
                    }
                }
            }.listStyle(.inset).disabled(store.busy)
            if rules.isEmpty { Text(ruleSearch.isEmpty ? "Add a rule for the selected folder." : "No rules match this search.").foregroundStyle(.secondary).padding(12) }
            HStack {
                Button { navigate(.newRule) } label: { Image(systemName: "plus") }.accessibilityLabel("Add rule").disabled(store.current == nil || !editable)
                Spacer()
                Menu {
                    Button("Move up") { if let id = selectedRule {store.moveRule(id, -1)} }
                    Button("Move down") { if let id = selectedRule {store.moveRule(id, 1)} }
                } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Reorder selected rule").disabled(selectedRule == nil || dirty || !editable)
            }.padding(8)
        }
    }

    private func columnHeading(_ title: String) -> some View {
        HStack {Text(title).fontWeight(.medium).foregroundStyle(.secondary); Spacer()}.padding(.horizontal, 12).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var editor: some View {
        if store.showHistory {
            VStack(alignment: .leading, spacing: 12) {
                Text("History").font(.title2)
                ScrollView { HistoryList() }
                Text("Undo newest actions first. Interrupted outcomes need manual inspection.").foregroundStyle(.secondary)
            }.padding(20)
        } else if let draft = store.editor {
            ReplicaRuleEditor(draft: draft, onDirty: { dirty = $0; store.hasUnsavedRuleChanges = $0 }, onSaved: { rule in
                selectedRule = rule.id; dirty = false; store.editor = RuleDraft(rule)
            }, onDiscard: {
                dirty = false; store.hasUnsavedRuleChanges = false
                if let rule = store.current?.rules.first(where: {$0.id == selectedRule}) { store.editor = RuleDraft(rule) }
                else { store.editor = nil }
            }).id(draft.id)
        } else if let rule = store.current?.rules.first(where: {$0.id == selectedRule}) {
            VStack(alignment: .leading, spacing: 12) {
                Text(rule.name).font(.title2)
                Text(rule.predicates.map(conditionName).joined(separator: "\n"))
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in Text(actionName(action)) }
                Button("Edit rule") { navigate(.rule(rule)) }
                Spacer()
            }.padding(20)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(store.current == nil ? "Choose a folder" : "Select or create a rule").font(.title2)
                Text("A rule checks conditions, then performs its actions in order.").foregroundStyle(.secondary)
                if store.current != nil { Button("New rule") { navigate(.newRule) }.disabled(!editable) }
                Text("Direct files only. Preview before applying. Background rules start paused.").font(.callout).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func navigate(_ route: Route) {
        guard !store.busy else {return}
        if dirty { pendingRoute = route; discardConsent = true } else { perform(route) }
    }
    private func perform(_ route: Route) {
        dirty = false; store.hasUnsavedRuleChanges = false; store.showHistory = false
        switch route {
        case .folder(let id): store.editor = nil; selectedRule = nil; store.selected = id
        case .rule(let rule): selectedRule = rule.id; store.editRule(rule)
        case .newRule: selectedRule = nil; store.editRule()
        case .history: store.editor = nil; store.pauseBackground(); store.reloadHistory(); store.showHistory = true
        case .addFolder: store.editor = nil; selectedRule = nil; store.addFolder()
        case .sample: store.editor = nil; selectedRule = nil; store.addFolder(sample: true)
        }
    }

    private func openStatus(_ mode: ReplicaRuleStatus.Mode) {
        statusMode = mode
        if mode == .ruleStatus { store.reloadHistory() }
        store.preview = nil
        store.check()
        showStatus = true
    }

    private func refreshStatus() {
        if statusMode == .ruleStatus { store.reloadHistory() }
        store.preview = nil
        store.check()
    }
}

private struct ReplicaRuleStatus: View {
    enum Mode: Equatable { case preview, ruleStatus }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2)
                Spacer()
                Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)
            }
            if mode == .ruleStatus { ruleStatusBody } else { previewBody }
        }
        .padding(20)
        .frame(minWidth: mode == .ruleStatus ? 740 : 720,
               idealWidth: mode == .ruleStatus ? 880 : 840,
               minHeight: 420)
    }

    private var title: String {
        mode == .ruleStatus ? "Rule status · \(store.current?.name ?? "Folder")" : "Preview changes · \(store.current?.name ?? "Folder")"
    }

    @ViewBuilder private var ruleStatusBody: some View {
        Text("Current matches come from a read-only file check. Dates are from this app’s journal; no Hazel execution date is shown.")
            .foregroundStyle(.secondary)
        if store.busy {
            ProgressView("Checking selected folder…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if !store.storageHealthy {
            Text(store.message).foregroundStyle(.red).padding(.vertical, 24)
        } else if let preview = currentPreview {
            if preview.rows.isEmpty {
                Text("No direct files were found in the selected folder.").foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                Table(preview.rows) {
                    TableColumn("File") { row in
                        Text(URL(fileURLWithPath: row.sourcePath).lastPathComponent).help(row.sourcePath)
                    }
                    TableColumn("Current matching rule") { row in
                        Text(row.ruleName ?? (row.status == .blocked ? "Could not check" : "No matching rule"))
                    }
                    TableColumn("Last recorded date") { row in
                        Text(lastRecordedDate(for: row, folderID: preview.folderID))
                            .help("Date from this app’s operation journal for the selected folder and source path.")
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Spacer()
                Button("Refresh") { refresh() }.disabled(store.busy)
            }
        } else {
            Text(store.message).foregroundStyle(.secondary).padding(.vertical, 24)
            HStack { Spacer(); Button("Refresh") { refresh() }.disabled(store.busy || !store.storageHealthy) }
        }
    }

    @ViewBuilder private var previewBody: some View {
        Text(FileCopy.previewInstruction)
            .foregroundStyle(.secondary)
        if store.busy {
            ProgressView("Checking files…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if !store.storageHealthy {
            Text(store.message).foregroundStyle(.red).padding(.vertical, 24)
        } else if let preview = currentPreview {
            Table(preview.rows) {
                TableColumn("File") { row in Text(URL(fileURLWithPath: row.sourcePath).lastPathComponent).help(row.sourcePath) }
                TableColumn("Matched rule") { row in Text(row.ruleName ?? "No match") }
                TableColumn("Status") { row in Text(row.status.rawValue.capitalized) }
            }.frame(minHeight: 180)
            ScrollView { PreviewList() }.frame(maxHeight: 220)
            HStack {
                Button("Refresh") { refresh() }.disabled(store.busy)
                Spacer()
                Button("Apply reviewed changes") { store.apply() }
                    .disabled(store.busy || !store.storageHealthy || !preview.rows.contains(where: {$0.status == .ready}))
            }
        } else {
            Text(store.message).foregroundStyle(.secondary).padding(.vertical, 24)
            HStack { Spacer(); Button("Refresh") { refresh() }.disabled(store.busy || !store.storageHealthy) }
        }
    }

    private var currentPreview: FilesCore.Preview? {
        guard let selected = store.selected, store.preview?.folderID == selected else { return nil }
        return store.preview
    }

    private func lastRecordedDate(for row: PreviewRow, folderID: UUID) -> String {
        let record = store.records
            .filter { $0.folderID == folderID && $0.sourcePath == row.sourcePath }
            .max { journalDate($0) < journalDate($1) }
        guard let record else { return "No record" }
        let date = journalDate(record).formatted(date: .abbreviated, time: .shortened)
        switch record.state {
        case .interrupted, .intent, .undoIntent:
            return "Unknown outcome · \(date)"
        default:
            return date
        }
    }

    private func journalDate(_ record: OperationRecord) -> Date {
        record.finishedAt ?? record.createdAt
    }
}
