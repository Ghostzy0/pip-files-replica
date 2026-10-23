import SwiftUI
import AppKit
import FilesCore

struct PipView:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("pip.files.theme") var look = "paper"
    @AppStorage("pip.files.appearance") var appearance = "light"
    @State private var watchConsent = false
    @State private var removeConsent = false
    var palette:PipPalette {PipPalette(dark:appearance == "dark",oat:look == "oat")}
    var ready:Int {store.preview?.rows.filter {$0.status == .ready}.count ?? 0}
    var body:some View {
        HStack(spacing:0) {
            sidebar.frame(width:PipSpace.rail)
            Rectangle().fill(palette.line).frame(width:1)
            VStack(alignment:.leading,spacing:0) {
                header
                ScrollView {
                    VStack(alignment:.leading,spacing:PipSpace.section) {
                        if store.showHistory {history}
                        else if let folder = store.current {rules(folder); preview}
                        else {welcome}
                    }.padding(PipSpace.section).frame(maxWidth:.infinity,alignment:.leading)
                }
                status
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.foregroundStyle(palette.ink).background(palette.canvas).font(.system(size:15))
        .preferredColorScheme(appearance == "dark" ? .dark:.light)
        .tint(palette.ink)
        .sheet(isPresented:$watchConsent) {
            VStack(alignment:.leading,spacing:PipSpace.card) {
                Text("Run rules in the background?").font(.title2.weight(.semibold))
                Text("Pip Files will apply matching rules to stable files directly inside this selected folder while the app stays open.")
                Text(store.current?.path ?? "").font(.callout).textSelection(.enabled)
                Text("Files may move, be renamed, copied, tagged or archived as shown in your rules. A settling check cannot guarantee every writer has finished. Every launch starts paused.").foregroundStyle(.secondary)
                HStack {Button("Cancel") {watchConsent = false}.keyboardShortcut(.cancelAction);Spacer();Button("Enable background rules") {store.enableBackground();watchConsent = false}.keyboardShortcut(.defaultAction).buttonStyle(PipPrimaryStyle(palette:palette))}
            }.padding(PipSpace.section).frame(width:540).tint(palette.ink).background(palette.canvas).preferredColorScheme(appearance == "dark" ? .dark:.light)
        }
        .confirmationDialog("Remove this folder from Pip Files? Its files will be kept.",isPresented:$removeConsent) {Button("Remove folder",role:.destructive) {store.removeFolder()};Button("Cancel",role:.cancel){}}
    }
    var sidebar:some View {
        VStack(alignment:.leading,spacing:PipSpace.section) {
            HStack(spacing:PipSpace.row) {PipPebble(ink:palette.ink,eye:palette.canvas,busy:store.busy).frame(width:36,height:32);Text(FeatureEdition.current.name).font(.system(size:21,weight:.semibold))}.padding(.top,PipSpace.section)
            VStack(alignment:.leading,spacing:PipSpace.small) {
                HStack {Text("Folders").font(.system(size:13,weight:.semibold)).foregroundStyle(palette.secondary);Spacer();Text("\(store.folders.count)").font(.system(size:12,design:.monospaced)).foregroundStyle(palette.secondary)}
                ScrollView {
                    LazyVStack(spacing:PipSpace.tiny) {
                        ForEach(store.folders,id:\.id) {folder in
                            Button {store.selected = folder.id;store.showHistory = false} label: {
                                HStack(spacing:PipSpace.small) {Image(systemName:"folder");Text(folder.name).lineLimit(2);Spacer(minLength:0)}.padding(PipSpace.row).frame(maxWidth:.infinity,alignment:.leading).background(store.selected == folder.id && !store.showHistory ? palette.fill:Color.clear,in:RoundedRectangle(cornerRadius:PipSpace.radius))
                            }.buttonStyle(.plain).help(folder.path).accessibilityAddTraits(store.selected == folder.id ? .isSelected:[])
                        }
                    }
                }
                Button {store.addFolder()} label:{Label("Add folder",systemImage:"plus").frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.borderless).padding(PipSpace.small).disabled(store.busy || !store.storageHealthy)
            }
            Spacer(minLength:0)
            VStack(alignment:.leading,spacing:PipSpace.row) {
                Text("I check the rules.\nYou choose what changes.").font(.system(size:14)).foregroundStyle(palette.secondary).lineSpacing(PipSpace.tiny)
                Button {store.showHistory = true;store.reloadHistory()} label:{Label("History",systemImage:"clock.arrow.circlepath").frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.borderless).padding(.vertical,PipSpace.small)
                Menu {Picker("Theme",selection:$look) {Text("Paper").tag("paper");Text("Oat").tag("oat")};Picker("Appearance",selection:$appearance) {Text("Light").tag("light");Text("Dark").tag("dark")}} label:{Label("Look",systemImage:"circle.lefthalf.filled")}.menuStyle(.borderlessButton)
                Text("Local on this Mac · Alpha").font(.system(size:12)).foregroundStyle(palette.secondary)
            }
        }.padding(.horizontal,PipSpace.card).padding(.bottom,PipSpace.section).background(palette.surface)
    }
    var header:some View {
        VStack(alignment:.leading,spacing:PipSpace.small) {
            HStack(alignment:.center,spacing:PipSpace.row) {
                VStack(alignment:.leading,spacing:PipSpace.tiny) {
                    Text(store.showHistory ? "History":store.current?.name ?? "A little order for your files").font(.system(size:24,weight:.semibold)).tracking(-0.5)
                    Text(store.showHistory ? "A record of every applied action and its recovery state.":"Make a rule. Check the preview. Keep control.").font(.system(size:14)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength:PipSpace.small)
                if !store.showHistory, store.current != nil {
                    Button {store.check()} label:{Label("Preview",systemImage:"eye").frame(minHeight:22)}.buttonStyle(PipPrimaryStyle(palette:palette)).buttonBorderShape(.capsule).disabled(store.busy || !store.storageHealthy)
                }
            }
            if !store.showHistory,let folder = store.current {Text(folder.path).font(.system(size:12)).foregroundStyle(palette.secondary).lineLimit(2).textSelection(.enabled)}
        }.padding(PipSpace.section).padding(.top,PipSpace.card)
    }
    var welcome:some View {
        VStack(alignment:.leading,spacing:PipSpace.section) {
            Image(systemName:"folder.badge.gearshape").font(.system(size:40,weight:.light)).padding(.top,PipSpace.section).accessibilityHidden(true)
            Text("A place for everything.\nAt your pace.").font(.system(size:32,weight:.semibold)).tracking(-0.6)
            Text("Choose one folder to organise, or try a disposable sample first. New rules stay paused until you apply a preview or enable background rules.").foregroundStyle(palette.secondary).frame(maxWidth:490,alignment:.leading).lineSpacing(PipSpace.tiny)
            HStack(spacing:PipSpace.row) {Button("Create sample folder") {store.addFolder(sample:true)}.buttonStyle(PipPrimaryStyle(palette:palette)).buttonBorderShape(.capsule);Button("Choose folder…") {store.addFolder()}.buttonStyle(.bordered).buttonBorderShape(.capsule)}.disabled(store.busy || !store.storageHealthy)
            Text("No account. No upload. Only the folders you choose.").font(.system(size:13)).foregroundStyle(palette.secondary)
        }.padding(.vertical,PipSpace.section)
    }
    func rules(_ folder:FolderConfig)->some View {
        VStack(alignment:.leading,spacing:PipSpace.row) {
            HStack {Text("Rules").font(.system(size:17,weight:.semibold));Text("First match wins").font(.system(size:12)).foregroundStyle(palette.secondary);Spacer();Button {store.editRule()} label:{Label("Add rule",systemImage:"plus")}.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(store.busy || !store.storageHealthy)}
            if folder.rules.isEmpty {Text("Add a condition and an action, then preview the result.").foregroundStyle(palette.secondary).padding(.vertical,PipSpace.card)}
            ForEach(Array(folder.rules.enumerated()),id:\.element.id) {index,rule in
                VStack(alignment:.leading,spacing:PipSpace.row) {
                    HStack(spacing:PipSpace.row) {
                        Text(String(format:"%02d",index+1)).font(.system(size:12,design:.monospaced)).foregroundStyle(palette.secondary)
                        Text(rule.name).font(.system(size:15,weight:.semibold)).lineLimit(2)
                        Spacer()
                        Text(rule.enabled ? "On":"Off").font(.system(size:12)).foregroundStyle(palette.secondary)
                        Toggle("Enabled",isOn:Binding(get:{rule.enabled},set:{_ in store.toggleRule(rule.id)})).toggleStyle(.switch).labelsHidden().accessibilityLabel("Enable \(rule.name)")
                        Menu {Button("Edit rule") {store.editRule(rule)};Button("Move up") {store.moveRule(rule.id,-1)}.disabled(index == 0);Button("Move down") {store.moveRule(rule.id,1)}.disabled(index == folder.rules.count-1);Divider();Button("Remove rule",role:.destructive) {store.removeRule(rule.id)}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:28).accessibilityLabel("Options for \(rule.name)")
                    }
                    Text((rule.match == .all ? "All: ":"Any: ") + rule.predicates.map(conditionName).joined(separator:" · ")).font(.system(size:13)).foregroundStyle(palette.secondary)
                    ForEach(Array(rule.actions.enumerated()),id:\.offset) {_,action in Label(actionName(action),systemImage:"arrow.turn.down.right").font(.system(size:13)).foregroundStyle(palette.secondary).textSelection(.enabled)}
                }.padding(PipSpace.card).frame(maxWidth:.infinity,alignment:.leading).background(palette.surface,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).strokeBorder(palette.line,lineWidth:1)).disabled(store.busy || !store.storageHealthy)
            }
            HStack(spacing:PipSpace.small) {
                Image(systemName:store.watching ? "arrow.trianglehead.2.clockwise":"pause.circle").accessibilityHidden(true)
                Text(store.watching ? "Background rules enabled":"Background rules paused").font(.system(size:13))
                Spacer()
                Button(store.watching ? "Pause":"Enable…") {if store.watching {store.pauseBackground()} else {watchConsent = true}}.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled((store.busy && !store.watching) || folder.rules.isEmpty || !store.storageHealthy)
                Menu {Button("Reveal folder in Finder") {NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:folder.path)};Button("Remove folder…",role:.destructive){removeConsent = true}} label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:28).accessibilityLabel("Folder options").disabled(store.busy)
            }.foregroundStyle(palette.secondary).padding(.top,PipSpace.small)
        }
    }
    var preview:some View {
        VStack(alignment:.leading,spacing:PipSpace.row) {
            HStack {Text("Preview").font(.system(size:17,weight:.semibold));Spacer();if store.preview != nil {Text("\(ready) ready").font(.system(size:12,design:.monospaced)).foregroundStyle(palette.secondary)}}
            if let plan = store.preview {
                if plan.rows.isEmpty {Text("No direct files to check. Add a file to this folder, then preview again.").foregroundStyle(palette.secondary)}
                ForEach(plan.rows) {row in
                    VStack(alignment:.leading,spacing:PipSpace.small) {
                        HStack {Image(systemName:row.status == .ready ? "doc":"info.circle");Text(URL(fileURLWithPath:row.sourcePath).lastPathComponent).fontWeight(.medium).textSelection(.enabled);Spacer();Text(row.status.rawValue.capitalized).font(.system(size:12)).foregroundStyle(palette.secondary)}
                        ForEach(Array(row.actions.enumerated()),id:\.offset) {_,action in Text(actionName(action.action)).font(.system(size:13)).foregroundStyle(palette.secondary).textSelection(.enabled)}
                        if let issue = FileCopy.previewReason(row) {Text(issue).font(.system(size:13)).foregroundStyle(palette.secondary)}
                    }.padding(PipSpace.card).background(palette.surface,in:RoundedRectangle(cornerRadius:PipSpace.radius))
                }
                HStack {Text("Existing files are never replaced.").font(.system(size:13)).foregroundStyle(palette.secondary);Spacer();Button(ready == 1 ? "Apply 1 file":"Apply \(ready) files") {store.apply()}.buttonStyle(PipPrimaryStyle(palette:palette)).buttonBorderShape(.capsule).disabled(ready == 0 || store.busy || !store.storageHealthy)}
                if ready == 0 {Text("Apply needs at least one ready file. Check the reasons above, then preview again.").font(.system(size:13)).foregroundStyle(palette.secondary)}
            } else {Text("Preview shows the exact actions before anything changes. Press Preview after adding or editing a rule.").font(.system(size:14)).foregroundStyle(palette.secondary).padding(.vertical,PipSpace.card)}
        }
    }
    var history:some View {VStack(alignment:.leading,spacing:PipSpace.card) {HistoryList();Text("Undo newest actions first. Copy and ZIP results are kept in hidden recovery files. Interrupted actions need manual inspection in Finder.").font(.system(size:13)).foregroundStyle(palette.secondary)}}
    var status:some View {
        HStack(spacing:PipSpace.small) {
            if store.busy {if reduceMotion {Image(systemName:"hourglass")} else {ProgressView().controlSize(.small)}}
            else {Image(systemName:store.storageHealthy ? "info.circle":"exclamationmark.triangle")}
            Text(store.message).font(.system(size:13)).textSelection(.enabled)
            Spacer(minLength:0)
        }.foregroundStyle(palette.secondary).padding(PipSpace.card).frame(minHeight:56).background(palette.surface).accessibilityElement(children:.combine)
    }
}
