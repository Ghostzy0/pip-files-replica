import SwiftUI
import FilesCore

/// Compact in-pane editor: original controls following the observed/documented workflow.
struct ReplicaRuleEditor: View {
    @EnvironmentObject private var store: AppStore
    let draft: RuleDraft
    let onDirty: (Bool) -> Void
    let onSaved: (Rule) -> Void
    let onDiscard: () -> Void
    @State private var name: String
    @State private var mode: String
    @State private var conditions: [ConditionInput]
    @State private var actions: [ActionInput]
    @State private var error = ""

    init(draft: RuleDraft, onDirty: @escaping (Bool) -> Void, onSaved: @escaping (Rule) -> Void, onDiscard: @escaping () -> Void) {
        self.draft = draft; self.onDirty = onDirty; self.onSaved = onSaved; self.onDiscard = onDiscard
        _name = State(initialValue: draft.rule.name)
        _mode = State(initialValue: draft.rule.match.rawValue)
        _conditions = State(initialValue: draft.rule.predicates.map(ConditionInput.init))
        _actions = State(initialValue: draft.rule.actions.isEmpty ? [ActionInput()] : draft.rule.actions.map(ActionInput.init))
    }
    private var signature: [String] { [name, mode] + conditions.map {"c\($0.kind):\($0.value)"} + actions.map {"a\($0.kind):\($0.value)"} }
    private var originalSignature: [String] {
        let originalActions = draft.rule.actions.isEmpty ? [ActionInput()] : draft.rule.actions.map(ActionInput.init)
        return [draft.rule.name, draft.rule.match.rawValue]
            + draft.rule.predicates.map(ConditionInput.init).map {"c\($0.kind):\($0.value)"}
            + originalActions.map {"a\($0.kind):\($0.value)"}
    }
    private var dirty: Bool { signature != originalSignature }
    private var editable: Bool { !store.busy && store.storageHealthy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Name:")
                TextField("Rule name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Rule name")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) {
                        Text("If")
                        Picker("Match conditions", selection: $mode) { Text("all").tag("all"); Text("any").tag("any") }.labelsHidden().frame(width: 74)
                        Text("of these conditions match:")
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 4) {
                        ForEach($conditions) { $condition in
                            HStack(spacing: 6) {
                                Picker("Condition \(conditionIndex(condition.id))", selection: $condition.kind) {
                                    Text("Extension").tag(0); Text("Name").tag(1); Text("Size at least").tag(2); Text("Size at most").tag(3); Text("Age at least").tag(4); Text("Age at most").tag(5)
                                }.labelsHidden().frame(width: 136)
                                Text(condition.kind == 0 ? "is" : condition.kind == 1 ? "contains" : "").frame(width: condition.kind < 2 ? 58 : 0)
                                TextField("Value", text: $condition.value).textFieldStyle(.roundedBorder).accessibilityLabel("Condition \(conditionIndex(condition.id)) value")
                                if condition.kind > 1 { Text(condition.kind < 4 ? "bytes" : "seconds").foregroundStyle(.secondary) }
                                rowButton("Remove condition \(conditionIndex(condition.id))", icon: "minus") {conditions.removeAll {$0.id == condition.id}}.disabled(conditions.count == 1)
                                rowButton("Add condition after \(conditionIndex(condition.id))", icon: "plus") {conditions.insert(ConditionInput(), at: conditionIndex(condition.id))}
                            }.padding(6).background(Color(nsColor: .controlBackgroundColor)).overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        }
                    }
                    Text("Then perform these actions in order:")
                    VStack(spacing: 4) {
                        ForEach($actions) { $action in
                            HStack(spacing: 6) {
                                Picker("Action \(actionIndex(action.id))", selection: $action.kind) {
                                    Text("Move").tag(0); Text("Copy").tag(1); Text("Rename").tag(2); Text("Add Finder tag").tag(3); Text("Create ZIP").tag(4)
                                }.labelsHidden().frame(width: 136)
                                if [0,1,4].contains(action.kind) {
                                    Text("to folder:")
                                    Button { if let path = store.chooseDestination() {action.value = path} } label: {
                                        Label(action.value.isEmpty ? "Choose folder…" : URL(fileURLWithPath: action.value).lastPathComponent, systemImage: "folder")
                                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    }.help(action.value.isEmpty ? "Choose a destination folder" : action.value).accessibilityLabel("Choose destination for action \(actionIndex(action.id))")
                                } else {
                                    TextField(action.kind == 2 ? "Exact filename with extension" : "Tag name", text: $action.value).textFieldStyle(.roundedBorder).accessibilityLabel("Action \(actionIndex(action.id)) value")
                                }
                                rowButton("Remove action \(actionIndex(action.id))", icon: "minus") {actions.removeAll {$0.id == action.id}}.disabled(actions.count == 1)
                                rowButton("Add action after \(actionIndex(action.id))", icon: "plus") {actions.insert(ActionInput(), at: actionIndex(action.id))}
                            }.padding(6).background(Color(nsColor: .controlBackgroundColor)).overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        }
                    }
                    if !error.isEmpty {Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)}
                    Text("Only direct files are checked. The first enabled matching rule wins. Existing files are never replaced.").font(.callout).foregroundStyle(.secondary)
                    Text("Size uses bytes. Age is time since last modification, in seconds.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Discard") {onDiscard()}.keyboardShortcut(.cancelAction)
                        Button("Save") {save()}.keyboardShortcut(.defaultAction).disabled(!editable)
                    }
                }.padding(16)
            }
            Spacer(minLength: 0)
            if let folder = store.current {
                Divider()
                Label(folder.path, systemImage: "folder").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(12)
            }
        }.disabled(!editable)
        .onAppear {onDirty(dirty)}
        .onChange(of: signature) { _, _ in onDirty(dirty); error = "" }
    }
    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {Image(systemName: icon).frame(width: 14, height: 16)}.buttonStyle(.bordered).help(title).accessibilityLabel(title)
    }
    private func conditionIndex(_ id: UUID) -> Int {(conditions.firstIndex {$0.id == id} ?? 0) + 1}
    private func actionIndex(_ id: UUID) -> Int {(actions.firstIndex {$0.id == id} ?? 0) + 1}
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !conditions.isEmpty, !actions.isEmpty,
              conditions.allSatisfy({$0.predicate != nil}), actions.allSatisfy({!$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty}) else {
            error = "Add a name, valid conditions and a destination or value for every action."; return
        }
        let rule = Rule(id: draft.rule.id, name: name, enabled: draft.rule.enabled, match: mode == "all" ? .all : .any, predicates: conditions.compactMap(\.predicate), actions: actions.map(\.action))
        guard store.updateRule(rule) else {error = "The rule could not be saved. Keep these details before reopening."; return}
        onDirty(false); onSaved(rule)
    }
}
