import SwiftUI
import FilesCore

struct ConditionInput: Identifiable {
    var id = UUID(); var kind = 0; var value = "pdf"
    init(_ predicate: FilesCore.Predicate = .fileExtension("pdf")) {
        switch predicate {
        case .fileExtension(let s): kind = 0; value = s
        case .nameContains(let s): kind = 1; value = s
        case .minimumSize(let n): kind = 2; value = String(n)
        case .maximumSize(let n): kind = 3; value = String(n)
        case .minimumAge(let n): kind = 4; value = String(n)
        case .maximumAge(let n): kind = 5; value = String(n)
        }
    }
    var predicate: FilesCore.Predicate? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {return nil}
        switch kind {
        case 0: return .fileExtension(value)
        case 1: return .nameContains(value)
        case 2: return Int64(value).flatMap {$0 >= 0 ? .minimumSize($0) : nil}
        case 3: return Int64(value).flatMap {$0 >= 0 ? .maximumSize($0) : nil}
        case 4: return Double(value).flatMap {$0 >= 0 && $0.isFinite ? .minimumAge($0) : nil}
        default: return Double(value).flatMap {$0 >= 0 && $0.isFinite ? .maximumAge($0) : nil}
        }
    }
}
struct ActionInput: Identifiable {
    var id = UUID(); var kind = 0; var value = ""
    init(_ action: FileAction = .move(to:"")) {
        switch action {
        case .move(let s): kind = 0; value = s
        case .copy(let s): kind = 1; value = s
        case .rename(let s): kind = 2; value = s
        case .tag(let s): kind = 3; value = s
        case .zipArchive(let s): kind = 4; value = s
        }
    }
    var action: FileAction {
        switch kind {case 0:return .move(to:value); case 1:return .copy(to:value); case 2:return .rename(to:value); case 3:return .tag(value);default:return .zipArchive(to:value)}
    }
}
struct RuleEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let draft: RuleDraft
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pip.files.theme") private var look = "paper"
    private var isBaseline:Bool {FeatureEdition.current.baseline}
    private var palette:PipPalette {PipPalette(dark:colorScheme == .dark,oat:look == "oat")}
    @State private var name: String
    @State private var mode: String
    @State private var conditions: [ConditionInput]
    @State private var actions: [ActionInput]
    @State private var error = ""
    init(draft:RuleDraft) {
        self.draft = draft
        _name = State(initialValue: draft.rule.name)
        _mode = State(initialValue: draft.rule.match.rawValue)
        _conditions = State(initialValue: draft.rule.predicates.map(ConditionInput.init))
        _actions = State(initialValue: draft.rule.actions.map(ActionInput.init))
    }
    var body: some View {
        VStack(alignment:.leading, spacing:16) {
            HStack { Text("Edit rule").font(.title2.weight(.semibold)); Spacer(); Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction) }
            TextField("Rule name",text:$name).textFieldStyle(.roundedBorder)
            HStack {Text("Match"); Picker("Match",selection:$mode) {Text("All conditions").tag("all");Text("Any condition").tag("any")}.pickerStyle(.segmented).labelsHidden()}
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach($conditions) { $condition in
                        HStack {
                            Picker("Condition",selection:$condition.kind) {Text("Extension is").tag(0);Text("Name contains").tag(1);Text("Size at least (bytes)").tag(2);Text("Size at most (bytes)").tag(3);Text("Age at least (seconds)").tag(4);Text("Age at most (seconds)").tag(5)}.frame(width:200)
                            TextField("Value",text:$condition.value).textFieldStyle(.roundedBorder).accessibilityLabel("Condition \(conditionIndex(condition.id)) value")
                            Button {conditions.removeAll {$0.id == condition.id}} label:{Image(systemName:"minus.circle")}.help("Remove condition").accessibilityLabel("Remove condition \(conditionIndex(condition.id))")
                        }
                    }
                    Button("Add condition") {conditions.append(ConditionInput())}
                    Divider().padding(.vertical,4)
                    Text("Then, in this order").font(.headline)
                    ForEach($actions) { $action in
                        HStack(alignment:.center) {
                            Picker("Action \(actionIndex(action.id))",selection:$action.kind) {Text("Move to").tag(0);Text("Copy to").tag(1);Text("Rename to").tag(2);Text("Add Finder tag").tag(3);Text("Create ZIP in").tag(4)}.frame(width:150)
                            if [0,1,4].contains(action.kind) {
                                Text(action.value.isEmpty ? "Choose a destination folder" : action.value).font(.caption).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                                Button("Choose…") {if let path = store.chooseDestination() {action.value = path}}.accessibilityLabel("Choose destination for action \(actionIndex(action.id))")
                            } else {TextField(action.kind == 2 ? "Exact filename, including extension" : "Tag name",text:$action.value).textFieldStyle(.roundedBorder).accessibilityLabel("Action \(actionIndex(action.id)) value")}
                            Button {actions.removeAll {$0.id == action.id}} label:{Image(systemName:"minus.circle")}.help("Remove action").accessibilityLabel("Remove action \(actionIndex(action.id))")
                        }
                    }
                    Button("Add action") {actions.append(ActionInput())}
                }
            }.frame(minHeight:180,maxHeight:360)
            Text("Direct files only. First matching rule wins. Existing files are never replaced.").font(.callout).foregroundStyle(.secondary)
            if !error.isEmpty {Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText)}
            HStack {Spacer();Group {if isBaseline {saveButton} else {saveButton.buttonStyle(PipPrimaryStyle(palette:palette))}}}
        }.padding(24).frame(width:720)
    }
    var saveButton:some View {Button("Save rule") {save()}.keyboardShortcut(.defaultAction).disabled(store.busy || !store.storageHealthy)}
    func conditionIndex(_ id:UUID)->Int {(conditions.firstIndex(where:{$0.id == id}) ?? 0)+1}
    func actionIndex(_ id:UUID)->Int {(actions.firstIndex(where:{$0.id == id}) ?? 0)+1}
    func save() {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !conditions.isEmpty, !actions.isEmpty,
              conditions.allSatisfy({$0.predicate != nil}), actions.allSatisfy({!$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {
            error = "Add a name, valid conditions and at least one complete action.";return
        }
        let rule = Rule(id:draft.rule.id,name:name,enabled:draft.rule.enabled,match:mode == "all" ? .all : .any,predicates:conditions.compactMap(\.predicate),actions:actions.map(\.action))
        guard store.updateRule(rule) else {error = "Your rule could not be saved. Keep these details before reopening the app.";return}
        dismiss()
    }
}

func actionName(_ action:FileAction) -> String {
    switch action {
    case .copy(let path):return "Copy to \(path)"
    case .move(let path):return "Move to \(path)"
    case .rename(let name):return "Rename to \(name)"
    case .tag(let name):return "Tag \(name)"
    case .zipArchive(let path):return "Create ZIP in \(path)"
    }
}
func conditionName(_ predicate:FilesCore.Predicate) -> String {
    switch predicate {
    case .fileExtension(let value):return "Extension is \(value)"
    case .nameContains(let value):return "Name contains \(value)"
    case .minimumSize(let value):return "Size at least \(value) bytes"
    case .maximumSize(let value):return "Size at most \(value) bytes"
    case .minimumAge(let value):return "Age at least \(String(value)) seconds"
    case .maximumAge(let value):return "Age at most \(String(value)) seconds"
    }
}
