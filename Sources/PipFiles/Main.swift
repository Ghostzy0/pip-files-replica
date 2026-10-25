import SwiftUI
import AppKit
import FilesCore

@MainActor
final class FilesAppDelegate:NSObject,NSApplicationDelegate,ObservableObject {
    enum ExitRequest {
        case quit
        case closeWindow(NSWindow)
    }

    @Published private(set) var pendingExit:ExitRequest?
    private weak var store:AppStore?
    private var windowDelegates:[ObjectIdentifier:WindowCloseDelegateProxy] = [:]
    private var discardCloseApprovals:Set<ObjectIdentifier> = []
    private var terminationReplyPending = false

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard !terminationReplyPending else {return .terminateCancel}
        // A window-close confirmation already owns the shared prompt. Cancel this
        // overlapping quit request; the user can retry Quit after resolving it.
        if case .closeWindow = pendingExit {return .terminateCancel}
        guard FeatureEdition.current.referenceLayout, store?.hasUnsavedRuleChanges == true else {return .terminateNow}
        terminationReplyPending = true
        pendingExit = .quit
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}

    func attach(store:AppStore, to window:NSWindow) {
        guard FeatureEdition.current.referenceLayout else {return}
        self.store = store
        let key = ObjectIdentifier(window)
        if let proxy = windowDelegates[key], window.delegate === proxy {return}
        let proxy = WindowCloseDelegateProxy(owner:self, store:store, forwarding:window.delegate)
        windowDelegates[key] = proxy
        window.delegate = proxy
    }

    fileprivate func requestClose(_ window:NSWindow) {
        guard case nil = pendingExit else {return}
        pendingExit = .closeWindow(window)
    }

    fileprivate func approveDiscardClose(_ window:NSWindow) {
        discardCloseApprovals.insert(ObjectIdentifier(window))
    }

    fileprivate func takeDiscardCloseApproval(for window:NSWindow)->Bool {
        discardCloseApprovals.remove(ObjectIdentifier(window)) != nil
    }

    fileprivate func windowDidClose(_ window:NSWindow) {
        windowDelegates.removeValue(forKey:ObjectIdentifier(window))
    }

    func keepEditing() {
        let request = pendingExit
        pendingExit = nil
        if let request, case .quit = request {
            terminationReplyPending = false
            NSApp.reply(toApplicationShouldTerminate:false)
        }
    }

    func dismissExitPromptIfNeeded() {
        if pendingExit != nil {keepEditing()}
    }

    func discardAndExit() {
        guard let request = pendingExit else {return}
        pendingExit = nil
        switch request {
        case .quit:
            store?.hasUnsavedRuleChanges = false
            terminationReplyPending = false
            NSApp.reply(toApplicationShouldTerminate:true)
        case .closeWindow(let window):
            approveDiscardClose(window)
            window.performClose(nil)
            discardCloseApprovals.remove(ObjectIdentifier(window))
            // If AppKit or the prior delegate prevented closing, keep the live
            // editor protected instead of marking its draft clean.
            if window.isVisible {store?.hasUnsavedRuleChanges = true}
        }
    }
}

@MainActor
private final class WindowCloseDelegateProxy:NSObject,NSWindowDelegate {
    weak var owner:FilesAppDelegate?
    private weak var store:AppStore?
    private let forwarding: (any NSWindowDelegate)?

    init(owner:FilesAppDelegate, store:AppStore, forwarding:(any NSWindowDelegate)?) {
        self.owner = owner
        self.store = store
        self.forwarding = forwarding
    }

    func windowShouldClose(_ sender:NSWindow)->Bool {
        if owner?.takeDiscardCloseApproval(for:sender) == true {
            let allowed = forwarding?.windowShouldClose?(sender) ?? true
            if allowed {store?.hasUnsavedRuleChanges = false}
            return allowed
        }
        if FeatureEdition.current.referenceLayout, store?.hasUnsavedRuleChanges == true {
            owner?.requestClose(sender)
            return false
        }
        return forwarding?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification:Notification) {
        forwarding?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow {owner?.windowDidClose(window)}
    }

    override func responds(to selector:Selector!)->Bool {
        super.responds(to:selector) || (forwarding?.responds(to:selector) ?? false)
    }

    override func forwardingTarget(for selector:Selector!)->Any? {
        if forwarding?.responds(to:selector) == true {return forwarding}
        return super.forwardingTarget(for:selector)
    }
}

private final class WindowCloseGuardView:NSView {
    weak var appDelegate:FilesAppDelegate?
    weak var store:AppStore?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, let store {appDelegate?.attach(store:store, to:window)}
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let appDelegate:FilesAppDelegate
    let store:AppStore

    func makeNSView(context:Context)->NSView {
        let view = WindowCloseGuardView()
        view.appDelegate = appDelegate
        view.store = store
        return view
    }

    func updateNSView(_ nsView:NSView, context:Context) {
        guard let view = nsView as? WindowCloseGuardView else {return}
        view.appDelegate = appDelegate
        view.store = store
        if let window = view.window {appDelegate.attach(store:store, to:window)}
    }
}

private struct ExitPromptModifier: ViewModifier {
    @ObservedObject var appDelegate:FilesAppDelegate

    func body(content:Content)->some View {
        content.confirmationDialog("Unsaved rule changes",isPresented:Binding(get:{if case nil = appDelegate.pendingExit {false} else {true}},set:{showing in
            if !showing {DispatchQueue.main.async {appDelegate.dismissExitPromptIfNeeded()}}
        })) {
            Button("Keep Editing",role:.cancel) {appDelegate.keepEditing()}.keyboardShortcut(.defaultAction)
            Button("Discard Changes",role:.destructive) {appDelegate.discardAndExit()}
        } message: {Text("Discarding closes without saving your rule changes.")}
    }
}

@main struct PipFilesApp: App {
    @NSApplicationDelegateAdaptor(FilesAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @AppStorage("pip.files.theme") private var look = "paper"
    @AppStorage("pip.files.appearance") private var appearance = "light"
    private var baseline:Bool {FeatureEdition.current.baseline}
    private var palette:PipPalette {PipPalette(dark:appearance == "dark",oat:look == "oat")}
    var body: some Scene {
        WindowGroup {
            Group {
                if FeatureEdition.current.referenceLayout { HazelReplicaView() }
                else if baseline { BaselineView() }
                else { PipView() }
            }.environmentObject(store)
                .background(WindowCloseGuard(appDelegate:appDelegate,store:store).frame(width:1,height:1).allowsHitTesting(false).accessibilityHidden(true))
                .frame(minWidth:900,minHeight:620)
                .modifier(ExitPromptModifier(appDelegate:appDelegate))
                .onDisappear {store.pauseBackground()}
                .onChange(of:store.selected) { _, _ in if store.watching {store.pauseBackground()};store.preview = nil; store.watching = false; store.showHistory = false }
                .onChange(of:store.showHistory) { _, showing in if showing {if store.watching {store.message = "Background rules paused while viewing History."};store.watching = false;store.preview = nil} }
                .sheet(item:Binding(get:{FeatureEdition.current.referenceLayout ? nil : store.editor},set:{if !FeatureEdition.current.referenceLayout { store.editor = $0 }})) {draft in
                    Group {
                        if baseline {RuleEditor(draft:draft).environmentObject(store)}
                        else {RuleEditor(draft:draft).environmentObject(store).tint(palette.ink).preferredColorScheme(appearance == "dark" ? .dark:.light).background(palette.canvas)}
                    }
                }
        }.defaultSize(width:1100,height:780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) {Button("Add folder…") {store.addFolder()}.keyboardShortcut("o")}
            CommandMenu("Rules") {
                Button("Preview") {store.check()}.keyboardShortcut("p",modifiers:[.command,.option]).disabled(store.current == nil || store.busy)
                Button("Pause background rules") {store.pauseBackground()}.keyboardShortcut(".")
            }
            CommandGroup(replacing:.appInfo) {Button("About \(FeatureEdition.current.name)") {NSApplication.shared.orderFrontStandardAboutPanel(options:[.applicationName:FeatureEdition.current.name,.applicationVersion:FeatureEdition.current.version,.credits:NSAttributedString(string:"Independent experimental folder workflow by Ghostzy0\nMaintainer: Ghostzy0\nMIT · Experimental · macOS 14+\nhttps://github.com/Ghostzy0/pip-files-replica\nHazel is a workflow reference. No affiliation.")])}}
        }
    }
}

struct BaselineView: View {
    @EnvironmentObject var store: AppStore
    @State private var watchConsent = false
    var body: some View {
        NavigationSplitView {
            List(selection:$store.selected) {ForEach(store.folders,id:\.id) {Text($0.name).tag($0.id)}}
            .navigationSplitViewColumnWidth(min:220,ideal:250,max:320)
            HStack {Button("Add folder") {store.addFolder()};Button("Sample") {store.addFolder(sample:true)}}.padding()
            Button("History") {store.showHistory.toggle()}.padding(.bottom)
        } detail: {
            VStack(alignment:.leading,spacing:16) {
                Text(store.current?.name ?? "Folder rules baseline").font(.title)
                Text(store.current?.path ?? "Original behavioural baseline. Select only disposable folders for testing.").textSelection(.enabled)
                if store.showHistory {ScrollView {HistoryList()}}
                else {
                    HStack {Button("Add rule") {store.editRule()}.disabled(store.current == nil);Button("Preview") {store.check()}.disabled(store.current == nil || store.busy);Button("Apply reviewed changes") {store.apply()}.disabled(store.preview?.rows.contains(where:{$0.status == .ready}) != true || store.busy)}
                    HStack {Text(store.watching ? "Background rules enabled":"Background rules paused");Button(store.watching ? "Pause":"Enable…") {if store.watching {store.pauseBackground()} else {watchConsent = true}}.disabled(store.current?.rules.isEmpty != false || store.busy || !store.storageHealthy)}
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            ForEach(store.current?.rules ?? [],id:\.id) {rule in
                                HStack {Toggle(rule.name,isOn:Binding(get:{rule.enabled},set:{_ in store.toggleRule(rule.id)}));Button("Edit") {store.editRule(rule)};Menu("Order") {Button("Move up") {store.moveRule(rule.id,-1)};Button("Move down") {store.moveRule(rule.id,1)};Button("Remove rule",role:.destructive) {store.removeRule(rule.id)}}}.disabled(store.busy || !store.storageHealthy)
                            }
                            PreviewList()
                        }
                    }
                }
                Spacer(minLength:0)
                Text(store.message).foregroundStyle(.secondary)
            }.padding(24)
        }.confirmationDialog("Enable background rules for this selected folder?",isPresented:$watchConsent) {Button("Enable background rules") {store.enableBackground()};Button("Cancel",role:.cancel){}} message:{Text("Only direct stable files are checked while this app stays open. Rules may move, rename, copy, tag or archive files. Every launch starts paused.")}
    }
}
struct PreviewList: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let preview = store.preview {
                Text("Preview · \(preview.rows.filter {$0.status == .ready}.count) ready").font(.headline)
                if preview.rows.isEmpty {Text("This folder has no direct files to check.").foregroundStyle(.secondary)}
                ForEach(preview.rows) {row in
                    VStack(alignment:.leading,spacing:4) {
                        HStack {Image(systemName:row.status == .ready ? "doc" : "info.circle");Text(URL(fileURLWithPath:row.sourcePath).lastPathComponent).fontWeight(.medium);Spacer();Text(row.status.rawValue.capitalized).font(.caption)}
                        if let rule = row.ruleName {Text(rule).font(.caption).foregroundStyle(.secondary)}
                        ForEach(Array(row.actions.enumerated()),id:\.offset) {_,action in Text(actionName(action.action)).font(.callout).textSelection(.enabled)}
                        if let issue = FileCopy.previewReason(row) {Text(issue).font(.callout).foregroundStyle(.secondary)}
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:14))
                }
            } else {Text("Preview lists proposed changes without changing your files.").foregroundStyle(.secondary)}
        }
    }
}
struct HistoryList: View {
    var body: some View {
        if FeatureEdition.current.enhanced { EnhancedHistory() }
        else { HistoryRows() }
    }
}

struct HistoryRows: View {
    @EnvironmentObject var store: AppStore
    var records: [OperationRecord]? = nil
    var emptyMessage: String? = nil
    var secondaryInk: Color? = nil
    private var visibleRecords: [OperationRecord] {records ?? store.records}
    var body: some View {
            LazyVStack(alignment:.leading,spacing:12) {
                if visibleRecords.isEmpty {Text(emptyMessage ?? (store.storageHealthy ? "No operations yet. Applied changes and recovery details appear here." : "History is unavailable. Saved records are kept. Reopen after checking the data folder.")).foregroundStyle(secondaryInk ?? Color.primary.opacity(0.75))}
                ForEach(visibleRecords) {record in
                    VStack(alignment:.leading,spacing:4) {
                        HStack {Text(URL(fileURLWithPath:record.sourcePath).lastPathComponent).fontWeight(.semibold);Spacer();Text(record.state.rawValue.capitalized).font(.caption);if record.state == .completed && !store.records.contains(where: {$0.rowID == record.rowID && $0.state == .completed && $0.createdAt > record.createdAt}) {Button("Undo") {store.undo(record.id)}.disabled(store.busy)}}
                        Text(actionName(record.action)).textSelection(.enabled)
                        Text("Source: \(record.sourcePath)").font(.caption).textSelection(.enabled)
                        if let destination = record.destinationPath {Text("Result: \(destination)").font(.caption).textSelection(.enabled)}
                        HStack {Button("Reveal source folder") {NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:URL(fileURLWithPath:record.sourcePath).deletingLastPathComponent().path)};if let destination = record.destinationPath {Button("Reveal result folder") {NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:URL(fileURLWithPath:destination).deletingLastPathComponent().path)}}}.font(.caption)
                        if let recovery = record.recoveryPath {Text("Recovery file: \(recovery)").font(.caption).textSelection(.enabled);Button("Reveal recovery folder") {NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:URL(fileURLWithPath:recovery).deletingLastPathComponent().path)}.font(.caption)}
                        if record.state == .interrupted || record.state == .intent || record.state == .undoIntent {ForEach([record.stagingPath,record.undoStagingPath].compactMap {$0},id:\.self) {path in Text("Staging path: \(path)").font(.caption).textSelection(.enabled)}}
                        Text(record.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(secondaryInk ?? Color.primary.opacity(0.75))
                        if record.issue != nil {Text(FileCopy.uncertain).font(.caption).foregroundStyle(secondaryInk ?? Color.primary.opacity(0.75))}
                        if record.state == .interrupted || record.state == .intent {Text("Outcome uncertain. Inspect both paths in Finder before doing anything else.").foregroundStyle(.red)}
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:14))
                }
            }
    }
}
