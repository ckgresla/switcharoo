import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

// Native preferences share the launcher's quiet, neutral visual vocabulary.
// Controls and placement previews use monochrome contrast.
final class WMPreferencesState: ObservableObject {
    static let shared = WMPreferencesState()
    @Published var draft = WindowManager.shared.configuration
    @Published var selection = "left-half"
    @Published var search = ""
    @Published var message = ""
    @Published var error = false
    @Published var editing = false
}
struct WMPreferencesView: View {
    @ObservedObject var manager: WindowManager
    @ObservedObject private var state = WMPreferencesState.shared
    var embedded = false
    var onBack: (() -> Void)?
    init(manager: WindowManager,embedded: Bool = false,onBack: (() -> Void)? = nil) { self.manager = manager; self.embedded = embedded; self.onBack = onBack }
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var draft: WMConfiguration { get { state.draft } nonmutating set { state.draft = newValue } }
    private var selection: String { get { state.selection } nonmutating set { state.selection = newValue } }
    private var search: String { get { state.search } nonmutating set { state.search = newValue } }
    private var message: String { get { state.message } nonmutating set { state.message = newValue } }
    private var error: Bool { get { state.error } nonmutating set { state.error = newValue } }
    private var editing: Bool { get { state.editing } nonmutating set { state.editing = newValue } }
    private var changed: Bool { draft != manager.configuration }
    private var commandIndex: Int? { draft.commands.firstIndex { $0.id == selection } }
    private var sceneIndex: Int? { draft.scenes.firstIndex { "scene:\($0.id.uuidString)" == selection } }
    private var entries: [(id: String,name: String,symbol: String,shortcut: WMShortcut?)] {
        var items = draft.commands.map { (id: $0.id,name: $0.name,symbol: "rectangle",shortcut: $0.shortcut) }
        items += draft.scenes.map { (id: "scene:\($0.id.uuidString)",name: $0.name,symbol: "rectangle.3.group",shortcut: $0.shortcut) }
        items.append((id: "general",name: "General",symbol: "slider.horizontal.3",shortcut: nil))
        return items.filter { item in search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || (draft.commands.first { $0.id == item.id }?.alias.localizedCaseInsensitiveContains(search) ?? false) }
    }
    private var selectedName: String { draft.commands.first { $0.id == selection }?.name ?? draft.scenes.first { "scene:\($0.id.uuidString)" == selection }?.name ?? "General" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if editing {
                    Button { editing = false; searchFocused = true } label: { Image(systemName: "chevron.left").frame(width: 24,height: 28) }.buttonStyle(LauncherHoverStyle()).help("Back")
                    Text(selectedName).font(SwitcharooTypography.ui(size: 14,weight: .medium))
                } else {
                    if embedded { Button { onBack?() } label: { Image(systemName:"chevron.left").frame(width:24,height:28) }.buttonStyle(LauncherHoverStyle()).help("Back") }
                    TextField("Search window commands…",text: $state.search).textFieldStyle(.plain).font(SwitcharooTypography.ui(size: 17)).focused($searchFocused)
                        .onSubmit { if !entries.isEmpty { editing = true; searchFocused = false } }
                        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                }
                Spacer(minLength: 0)
                if changed { Circle().fill(ToolStyle.accent(scheme)).frame(width: 6,height: 6).help("Unsaved changes") }
            }.padding(.horizontal,22).frame(height: 54)
            Divider()
            if editing {
                ScrollView {
                    VStack(alignment: .leading,spacing: 18) {
                        if selection == "general" { general }
                        else if let index = commandIndex { commandEditor(index) }
                        else if let index = sceneIndex { sceneEditor(index) }
                    }.padding(24).frame(maxWidth: 640,alignment: .leading).frame(maxWidth: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries,id: \.id) { item in
                                HStack(spacing:10) {
                                    Button { selection = item.id; editing = true; searchFocused = false } label: {
                                        HStack(spacing:14) {
                                            Image(systemName:item.symbol).font(SwitcharooTypography.ui(size:17,weight:.light)).frame(width:24)
                                            Text(item.name).font(SwitcharooTypography.ui(size:14))
                                            Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(LauncherHoverStyle())
                                    if item.id != "general" { WMShortcutRecorder(shortcut:shortcutBinding(item.id)).frame(width:170,height:28) }
                                }.foregroundStyle(.primary).padding(.horizontal,14).frame(height:44)
                                    .background(selection == item.id ? Color.primary.opacity(0.075) : .clear,in:RoundedRectangle(cornerRadius:9)).id(item.id)
                            }
                            if entries.isEmpty { Text("No results").foregroundStyle(.secondary).padding(32) }
                        }.padding(10)
                    }.onChange(of: selection) { _,id in proxy.scrollTo(id,anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                if !message.isEmpty { Text(message).lineLimit(1).foregroundStyle(ToolStyle.secondary(scheme)) }
                Spacer(minLength: 0)
                if changed {
                    Button("Revert") { draft = manager.configuration; message = "" }.buttonStyle(LauncherHoverStyle())
                    Button("Save  ⌘S") { save() }.buttonStyle(LauncherHoverStyle()).keyboardShortcut("s",modifiers: .command)
                } else if !editing { Button("Edit  ↩") { if !entries.isEmpty { editing = true; searchFocused = false } }.buttonStyle(LauncherHoverStyle()) }
                Divider().frame(height: 16)
                Menu("Actions") {
                    Button("New command") { let command = WMCommand(id: UUID().uuidString,name: "Custom placement"); draft.commands.append(command); selection = command.id; editing = true }
                    Button("Capture layout") { capture() }.disabled(manager.capturing)
                    Button("General") { selection = "general"; editing = true }
                    Divider()
                    Button("Import…") { importSettings(); editing = true }
                    Button("Export…") { exportSettings() }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(SwitcharooTypography.ui(size: 12)).padding(.horizontal,20).frame(height: 44)
        }.font(SwitcharooTypography.ui(size: 13)).tint(ToolStyle.accent(scheme)).frame(minWidth: embedded ? 0 : 680,minHeight: embedded ? 0 : 540).background(ToolStyle.background(scheme))
            .onAppear { searchFocused = true }
            .onChange(of: search) { _,_ in if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id ?? "" } }
            .onExitCommand { if editing { editing = false; searchFocused = true } else { onBack?() } }
    }
    private func shortcutBinding(_ id: String) -> Binding<WMShortcut?> {
        Binding(get:{
            if let command = draft.commands.first(where:{$0.id == id}) { return command.shortcut }
            return draft.scenes.first(where:{"scene:"+$0.id.uuidString == id})?.shortcut
        },set:{ value in
            if let index = draft.commands.firstIndex(where:{$0.id == id}) { draft.commands[index].shortcut = value }
            else if let index = draft.scenes.firstIndex(where:{"scene:"+$0.id.uuidString == id}) { draft.scenes[index].shortcut = value }
        })
    }
    private func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selection } ?? 0
        selection = entries[(index+offset+entries.count)%entries.count].id
    }
    private func commandEditor(_ index: Int) -> some View {
        let binding = $state.draft.commands[index]
        return VStack(alignment: .leading,spacing: 14) {
            HStack {
                Spacer()
                Toggle("Enabled",isOn: binding.enabled).toggleStyle(.switch).controlSize(.small)
            }
            if draft.commands[index].operation == .placement {
                WMPlacementPreview(placement: draft.commands[index].placement,config: draft)
            }
            Grid(alignment: .leading,horizontalSpacing: 18,verticalSpacing: 12) {
                GridRow { Text("Name").foregroundStyle(.secondary); TextField("Command name",text: binding.name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Alias").foregroundStyle(.secondary); TextField("Alias",text: binding.alias).textFieldStyle(.roundedBorder) }
                GridRow { Text("Shortcut").foregroundStyle(.secondary); WMShortcutRecorder(shortcut: binding.shortcut).frame(height: 28) }
            }.font(SwitcharooTypography.ui(size: 12))
            if draft.commands[index].operation == .placement { WMPlacementEditor(placement: binding.placement) }
            Divider()
            HStack {
                Button("Try placement") { manager.execute(command: draft.commands[index]) }.help("Apply to the last active app window")
                Button("Duplicate") {
                    var command = draft.commands[index]; command.id = UUID().uuidString; command.name += " Copy"; command.builtIn = false; command.shortcut = nil
                    draft.commands.append(command); selection = command.id
                }
                Spacer()
                if draft.commands[index].builtIn {
                    Button("Reset command") { if let original = WMCommand.defaults.first(where: { $0.id == selection }) { draft.commands[index] = original } }
                } else {
                    Button("Delete",role: .destructive) { draft.commands.remove(at: index); selection = "general" }
                }
            }.controlSize(.small)
        }
    }
    private var general: some View {
        VStack(alignment: .leading,spacing: 16) {
            Toggle("Global shortcuts",isOn: $state.draft.enabled)
            Grid(alignment: .leading,horizontalSpacing: 20,verticalSpacing: 14) {
                GridRow { Text("Desktop edge gap"); numeric($state.draft.outerGap); Text("points").foregroundStyle(.secondary) }
                GridRow { Text("Gap between tiles"); numeric($state.draft.innerGap); Text("points").foregroundStyle(.secondary) }
                GridRow { Text("Grow / shrink step"); numeric($state.draft.resizeStep); Text("points").foregroundStyle(.secondary) }
            }.font(SwitcharooTypography.ui(size: 12))
            Toggle("Cycle halves: ½ → ⅔ → ⅓",isOn: $state.draft.cycleHalves)
            Toggle("Repeat half to move displays",isOn: $state.draft.repeatedHalfMovesDisplay)
            Divider()
            HStack {
                Text("Shortcut status").font(SwitcharooTypography.ui(size: 14,weight: .medium))
                Spacer()
                Button("Retry Shortcuts") { manager.retryShortcuts() }
            }
            if manager.issues.isEmpty {
                Label(manager.configuration.enabled ? "Shortcuts active" : "Shortcuts paused",systemImage: "checkmark.circle").font(SwitcharooTypography.ui(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(manager.issues,id: \.self) { Text($0).font(SwitcharooTypography.ui(size: 11)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Button("Export…") { exportSettings() }
                Button("Import…") { importSettings() }
                Button("Show settings file") { NSWorkspace.shared.selectFile(WindowManager.settingsURL.path,inFileViewerRootedAtPath: "") }
            }
        }.toggleStyle(.checkbox)
    }
    private func sceneEditor(_ index: Int) -> some View {
        VStack(alignment: .leading,spacing: 18) {
            TextField("Layout name",text: $state.draft.scenes[index].name).textFieldStyle(.roundedBorder)
            WMShortcutRecorder(shortcut: $state.draft.scenes[index].shortcut).frame(height: 28)
            ForEach(Array(draft.scenes[index].windows.enumerated()),id: \.element.id) { offset, item in
                DisclosureGroup {
                    WMPlacementEditor(placement: $state.draft.scenes[index].windows[offset].placement).padding(.top,12)
                    Button("Remove window",role: .destructive) { draft.scenes[index].windows.remove(at: offset) }.padding(.top,8)
                } label: {
                    VStack(alignment: .leading,spacing: 3) {
                        Text(item.appName).font(SwitcharooTypography.ui(size: 13,weight: .medium))
                        Text(item.title.isEmpty ? "Window \(item.ordinal+1)" : item.title).font(SwitcharooTypography.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Divider()
            }
            HStack {
                Button("Restore layout") { manager.restore(draft.scenes[index]) }
                Spacer()
                Button("Delete layout",role: .destructive) { draft.scenes.remove(at: index); selection = "general" }
            }
        }
    }
    private func numeric(_ value: Binding<Double>) -> some View {
        TextField("0",value: value,format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
    }
    private func save() {
        do { try manager.save(draft); message = manager.issues.isEmpty ? "Settings saved" : "Saved · Shortcut conflicts"; error = false }
        catch { message = error.localizedDescription; self.error = true }
    }
    private func capture() {
        manager.captureLayout { scene in
            if let scene { draft.scenes.append(scene); selection = "scene:\(scene.id.uuidString)"; editing = true }
            else { message = "No app windows could be captured."; error = true }
        }
    }
    private func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "switcharoo-window-management.json"; panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try WindowManager.encode(draft.validated()).write(to: url,options: .atomic); message = "Settings exported"; error = false }
            catch { message = error.localizedDescription; self.error = true }
        }
    }
    private func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else { throw WMValidationError(message: "Settings file is too large.") }
                draft = try JSONDecoder().decode(WMConfiguration.self,from: data).validated()
                selection = "general"; message = "Imported · Unsaved"; error = false
            } catch { message = error.localizedDescription; self.error = true }
        }
    }
}

struct WMPlacementEditor: View {
    @Binding var placement: WMPlacement
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            dimension("Width",value: $placement.width)
            dimension("Height",value: $placement.height)
            HStack {
                Text("Pin to").foregroundStyle(.secondary).frame(width: 58,alignment: .leading)
                Picker("Pin to",selection: $placement.anchor) { ForEach(WMAnchor.allCases,id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
            }
            offset("Offset X",value: $placement.offsetX)
            offset("Offset Y",value: $placement.offsetY)
            HStack {
                Text("Display").foregroundStyle(.secondary).frame(width: 58,alignment: .leading)
                Picker("Display",selection: $placement.display) { ForEach(WMDisplay.allCases,id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
                    .onChange(of: placement.display) { placement.displayID = nil }
            }
            if let id = placement.displayID {
                HStack {
                    Text("Saved display: \(WindowManager.screens().first(where: { $0.id == id })?.name ?? "Disconnected")").foregroundStyle(.secondary)
                    Button("Use display rule") { placement.displayID = nil }.controlSize(.small)
                }
            }
            Toggle("Apply window gaps",isOn: $placement.useGaps).toggleStyle(.checkbox)
        }.font(SwitcharooTypography.ui(size: 12))
    }
    private func dimension(_ name: String, value: Binding<WMMeasure?>) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 58,alignment: .leading)
            Toggle("Keep",isOn: Binding(get: { value.wrappedValue == nil },set: { value.wrappedValue = $0 ? nil : .percent(50) })).toggleStyle(.checkbox).frame(width: 70)
            if value.wrappedValue != nil {
                TextField("Size",value: Binding(get: { value.wrappedValue?.value ?? 50 },set: { value.wrappedValue?.value = $0 }),format: .number).textFieldStyle(.roundedBorder).frame(width: 75)
                Picker(name+" unit",selection: Binding(get: { value.wrappedValue?.unit ?? .percent },set: { value.wrappedValue?.unit = $0 })) {
                    Text("% of display").tag(WMUnit.percent); Text("points").tag(WMUnit.points)
                }.labelsHidden().frame(width: 125)
            }
            Spacer(minLength: 0)
        }
    }
    private func offset(_ name: String, value: Binding<WMMeasure>) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 58,alignment: .leading)
            TextField("Offset",value: value.value,format: .number).textFieldStyle(.roundedBorder).frame(width: 75)
            Picker(name+" unit",selection: value.unit) { Text("points").tag(WMUnit.points); Text("% of display").tag(WMUnit.percent) }.labelsHidden().frame(width: 125)
            Spacer()
        }
    }
}

struct WMPlacementPreview: View {
    let placement: WMPlacement
    let config: WMConfiguration
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let screen = CGRect(x: 0,y: 0,width: 1440,height: 900)
            let available = CGSize(width: max(1,size.width-32),height: max(1,size.height-20))
            let scale = min(available.width/screen.width,available.height/screen.height)
            let origin = CGPoint(x: (size.width-screen.width*scale)/2,y: (size.height-screen.height*scale)/2)
            let desktop = CGRect(origin: origin,size: .init(width: screen.width*scale,height: screen.height*scale))
            context.fill(Path(roundedRect: desktop,cornerRadius: 8),with: .color(.primary.opacity(0.045)))
            context.stroke(Path(roundedRect: desktop,cornerRadius: 8),with: .color(.primary.opacity(0.13)),lineWidth: 1)
            let r = WMGeometry.placement(placement,current: .init(x: 100,y: 100,width: 700,height: 500),screen: screen,outer: config.outerGap,inner: config.innerGap)
            guard r.minX.isFinite,r.minY.isFinite,r.width.isFinite,r.height.isFinite else { return }
            let window = CGRect(x: origin.x+r.minX*scale,y: origin.y+r.minY*scale,width: r.width*scale,height: r.height*scale).insetBy(dx: 1,dy: 1)
            let sky = ToolStyle.accent(scheme)
            context.fill(Path(roundedRect: window,cornerRadius: 5),with: .color(sky.opacity(0.22)))
            context.stroke(Path(roundedRect: window,cornerRadius: 5),with: .color(sky.opacity(0.85)),lineWidth: 1)
        }.frame(height: 100).accessibilityLabel("Window placement preview")
    }
}

struct WMShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: WMShortcut?
    func makeNSView(context: Context) -> WMRecorderButton {
        let button = WMRecorderButton(); button.bezelStyle = .rounded
        button.changed = { shortcut = $0 }; return button
    }
    func updateNSView(_ button: WMRecorderButton,context: Context) {
        button.changed = { shortcut = $0 }; button.shortcut = shortcut
        if !button.recording { button.title = WMRecorderButton.label(shortcut) }
    }
    static func dismantleNSView(_ button: WMRecorderButton,coordinator: ()) { button.finish() }
}
final class WMRecorderButton: NSButton {
    var shortcut: WMShortcut?
    var changed: ((WMShortcut?) -> Void)?
    var recording = false
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if recording { finish(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true; AppShortcuts.shared.beginRecording(); title = "Press shortcut…"
        resignObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in self?.finish() }
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    func finish() {
        guard recording else { return }
        recording = false
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer); resignObserver = nil }
        title = Self.label(shortcut); AppShortcuts.shared.endRecording()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 51 && event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty { shortcut = nil; finish(); changed?(nil); return }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey|optionKey|controlKey) != 0 else { title = "Include ⌘, ⌥, or ⌃"; return }
        shortcut = .init(keyCode: UInt32(event.keyCode),modifiers: modifiers); finish(); changed?(shortcut)
    }
    static func label(_ s: WMShortcut?) -> String {
        guard let s else { return "Record shortcut…" }
        let flags = (s.modifiers & 4096 != 0 ? "⌃" : "") + (s.modifiers & 2048 != 0 ? "⌥" : "") + (s.modifiers & 512 != 0 ? "⇧" : "") + (s.modifiers & 256 != 0 ? "⌘" : "")
        let names: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"Esc",76:"⌤",123:"←",124:"→",125:"↓",126:"↑"]
        return flags + (names[s.keyCode] ?? "Key \(s.keyCode)")
    }
}
final class WMPreferencesController {
    static let shared = WMPreferencesController()
    private var window: NSWindow?
    func show(fullscreen: Bool = false) {
        if let app = NSApp.delegate as? App,app.panel?.isVisible == true { app.dismissPanel() }
        if window == nil {
            let w = NSWindow(contentRect: .init(x: 0,y: 0,width: 760,height: 650),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
            w.title = "Window management"; w.isReleasedWhenClosed = false; w.minSize = .init(width: 680,height: 540)
            w.contentView = NSHostingView(rootView: WMPreferencesView(manager: .shared)); w.center(); window = w
        }
        window?.deminiaturize(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        if fullscreen,let window,!window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func snapshot(to url: URL, dark: Bool) {
        show(); window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in
            guard let view = self?.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds,to: rep)
            try? rep.representation(using: .png,properties: [:])?.write(to: url)
            self?.window?.appearance = nil
        }
    }
}


struct SwitcharooSettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var shortcuts = AppShortcuts.shared
    @Environment(\.colorScheme) private var scheme
    @State private var appearance = SwitcharooAppearance.saved
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Button { model.back() } label: { Image(systemName:"chevron.left").frame(width:28,height:30) }.buttonStyle(LauncherHoverStyle()).help("Back · Esc")
                Text("Settings").font(SwitcharooTypography.ui(size:14,weight:.medium))
                LauncherDragArea().frame(maxWidth:.infinity,maxHeight:.infinity)
            }.padding(.horizontal,18).frame(height:50)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("General").font(SwitcharooTypography.ui(size:12,weight:.medium)).foregroundStyle(.secondary)
                    HStack {
                        Text("Appearance")
                        Spacer()
                        Picker("Appearance",selection:$appearance) {
                            ForEach(SwitcharooAppearance.allCases,id:\.rawValue) { mode in Text(mode.title).tag(mode) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width:220)
                    }.frame(height:30)
                    Toggle("Launch at Login",isOn:Binding(get:{ launchAtLogin },set:setLogin)).toggleStyle(.checkbox)
                    if !loginError.isEmpty { Text(loginError).font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary) }
                    Divider()
                    Button { model.navigate(.windowControls) } label: {
                        HStack(spacing:12) {
                            Image(systemName:"rectangle.3.group").frame(width:22)
                            Text("Window Management")
                            Spacer()
                            Image(systemName:"chevron.right").font(SwitcharooTypography.ui(size:11)).foregroundStyle(.secondary)
                        }.padding(.horizontal,10).frame(height:38).contentShape(Rectangle())
                    }.buttonStyle(LauncherHoverStyle()).foregroundStyle(.primary)
                    Divider()
                    Text("Keyboard Shortcuts").font(SwitcharooTypography.ui(size:12,weight:.medium)).foregroundStyle(.secondary)
                    VStack(spacing:12) {
                        ForEach(AppShortcutID.allCases,id:\.rawValue) { id in shortcut(id) }
                        if !shortcuts.message.isEmpty { Text(shortcuts.message).font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary) }
                    }
                }.padding(24)
            }
        }.font(SwitcharooTypography.ui(size:13)).background(ToolStyle.background(scheme)).tint(ToolStyle.accent(scheme))
            .onChange(of:appearance) { _,mode in mode.save() }
            .onExitCommand { model.back() }
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Enable Switcharoo in System Settings → General → Login Items." : ""
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    private func shortcut(_ id: AppShortcutID) -> some View {
        HStack {
            Text(id.title)
            Spacer()
            WMShortcutRecorder(shortcut:Binding(get:{ shortcuts.configuration[id] },set:{ shortcuts.update(id,to:$0) }))
                .frame(width:170,height:28).help("Click to change shortcut")
                .contextMenu { Button("Reset Shortcut") { shortcuts.update(id,to:id.defaultShortcut) } }
        }
    }
}
