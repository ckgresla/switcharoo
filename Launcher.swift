import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

struct LaunchableApplication: Identifiable, Equatable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bundleID: String?
}
final class ApplicationCatalog: ObservableObject {
    static let shared = ApplicationCatalog()
    @Published private(set) var applications: [LaunchableApplication] = []
    @Published private(set) var runningPaths = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []
    init() {
        updateRunningPaths()
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.updateRunningPaths() })
        }
    }
    private func updateRunningPaths() {
        runningPaths = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL).map(\.path))
    }
    private var loading = false
    private(set) var refreshedAt: Date?
    private var icons: [String:NSImage] = [:]
    func refresh() {
        guard !loading,refreshedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }; loading = true
        if applications.isEmpty {
            applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
                guard let url = app.bundleURL else { return nil }
                return LaunchableApplication(name: LauncherSearch.applicationName([app.localizedName],url:url),url: url,bundleID: app.bundleIdentifier)
            }
        }
        // Finder lives directly in CoreServices, outside its Applications subfolder.
        let runningURLs = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.finder")
        let knownURLs = runningURLs + [finderURL].compactMap { $0 }
        DispatchQueue.global(qos: .utility).async {
            let roots = ["/Applications","/System/Applications","/System/Library/CoreServices/Applications",NSHomeDirectory()+"/Applications"].map { URL(fileURLWithPath:$0) }
            var found: [LaunchableApplication] = [],seen = Set<String>()
            for url in LauncherSearch.applicationURLs(in:roots,including:knownURLs) {
                let bundle = Bundle(url:url)
                if bundle?.object(forInfoDictionaryKey:"LSBackgroundOnly") as? Bool == true { continue }
                let key = bundle?.bundleIdentifier ?? url.path
                guard seen.insert(key).inserted,key != Bundle.main.bundleIdentifier else { continue }
                let name = LauncherSearch.applicationName([bundle?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String,bundle?.object(forInfoDictionaryKey:"CFBundleName") as? String],url:url)
                found.append(.init(name:name,url:url,bundleID:bundle?.bundleIdentifier))
            }
            let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.applications = sorted; self.loading = false; self.refreshedAt = Date() }
        }
    }
    func icon(_ app: LaunchableApplication) -> NSImage {
        if let cached = icons[app.id] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path); icons[app.id] = icon; return icon
    }
}

enum LauncherRoute: Equatable {
    case search, settings, schedule, timers, windowControls, calculator, calculatorHistory, calculatorSettings
    var title: String {
        switch self { case .search: return "Switcharoo"; case .settings: return "Settings"; case .schedule: return "My Schedule"; case .timers: return "Timers"; case .windowControls: return "Window controls"; case .calculator: return "Calculator"; case .calculatorHistory: return "Calculator History"; case .calculatorSettings: return "Calculator Settings" }
    }
    var tool: SwitcharooTool? { self == .schedule ? .schedule : self == .timers ? .timer : nil }
}
struct LauncherResult: Identifiable {
    enum Action { case openURL(URL), application(LaunchableApplication), route(LauncherRoute), command(String), toggleSystemAppearance, appearance(SwitcharooAppearance) }
    var id: String
    var title: String
    var detail: String
    var symbol: String
    var keywords = ""
    var action: Action
}
private let launcherPreferences = LauncherPreferences(defaults:
    CommandLine.arguments.contains("--launcher-demo") || CommandLine.arguments.contains("--launcher-preview") || CommandLine.arguments.contains("--focus-regression") || CommandLine.arguments.contains("--readme-preview")
    ? UserDefaults(suiteName:"switcharoo.launcher-preview")! : .standard)
final class LauncherModel: ObservableObject {
    @Published var query = ""
    @Published var actionItem: LauncherResult?
    @Published var showingPinPicker = false
    func pinCandidates(apps: [LaunchableApplication],config: WMConfiguration) -> [LauncherResult] {
        prepareResults(apps:apps,config:config); return cachedRanked
    }
    var selectedVisibleResult: LauncherResult? {
        guard showingCommands || !query.isEmpty else { return nil }
        return results(apps:ApplicationCatalog.shared.applications,config:WindowManager.shared.configuration).first { $0.id == selectedID }
    }
    static var barContext: LauncherResult { .init(id:"launcher-bar",title:"Switcharoo",detail:"Launcher",symbol:"rectangle",action:.route(.search)) }
    func openActions() { actionItem = selectedVisibleResult ?? Self.barContext }
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard route == .search, !showingPinPicker, actionItem == nil else { return false }
        let flags = event.modifierFlags.intersection([.command,.option,.shift,.control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && key == "k" && !LauncherController.shared.calculator.hasContent { openActions(); return true }
        guard !LauncherController.shared.calculator.hasContent else { return false }
        guard let selected = selectedVisibleResult else { return false }
        if let action = LauncherItemAction.actions(for:selected,model:self).first(where: { $0.key == key && $0.modifiers == flags && $0.enabled }) {
            action.run(); return true
        }
        return false
    }
    @Published var showingCommands = launcherPreferences.commandsOpen { didSet { launcherPreferences.commandsOpen = showingCommands } }
    @Published var expandsUpward = false
    @Published var usage = launcherPreferences.usage { didSet { cachedConfig = nil } }
    func saveUsage() { launcherPreferences.usage = usage; didChangeRoute?() }
    func togglePin(_ id: String) { usage.togglePin(id); saveUsage() }
    func resetForOpening() { if !query.isEmpty { query = "" } }
    private var cachedApps: [LaunchableApplication] = []
    private var cachedConfig: WMConfiguration?
    private var cachedRunning = Set<String>()
    private var cachedAll: [LauncherResult] = []
    private var cachedRanked: [LauncherResult] = []
    private var cachedQuick: [LauncherResult] = []
    private var cachedQuery: String?
    private var cachedMatches: [LauncherResult] = []
    func prepareResults(apps: [LaunchableApplication],config: WMConfiguration) {
        let running = ApplicationCatalog.shared.runningPaths
        guard cachedConfig != config || cachedApps != apps || cachedRunning != running else { return }
        cachedConfig = config; cachedApps = apps; cachedRunning = running; cachedQuery = nil
        cachedAll = allResults(apps:apps,config:config)
        let lookup = Dictionary(cachedAll.map { ($0.id,$0) },uniquingKeysWith:{first,_ in first})
        let fallback = recentApps.map { "app:"+$0 } + apps.filter { running.contains($0.id) }.map { "app:"+$0.id } + ["schedule","timers","window-controls"]
        let available = cachedAll.map(\.id)
        let quickIDs = usage.topThree(available:available,fallback:fallback)
        cachedQuick = quickIDs.compactMap { lookup[$0] }
        cachedRanked = usage.ranked(available:available,fallback:quickIDs).compactMap { lookup[$0] }
    }
    func quickResults(apps: [LaunchableApplication],config: WMConfiguration) -> [LauncherResult] {
        prepareResults(apps:apps,config:config); return cachedQuick
    }
    private func allResults(apps: [LaunchableApplication],config: WMConfiguration) -> [LauncherResult] {
        let applications = apps.map { LauncherResult(id: "app:"+$0.id,title: $0.name,detail: "Application",symbol: "app",action: .application($0)) }
        let commands = config.commands.filter(\.enabled).map { LauncherResult(id: "command:"+$0.id,title: $0.name,detail: "Window",symbol: "rectangle.split.2x1",keywords: $0.alias,action: .command($0.id)) }
        let scenes = config.scenes.map { LauncherResult(id: "scene:"+$0.id.uuidString,title: $0.name,detail: "Layout",symbol: "rectangle.3.group",action: .command("scene:"+$0.id.uuidString)) }
        return toolResults + appearanceResults + applications + commands + scenes
    }
    private var appearanceResults: [LauncherResult] {
        [.init(id:"system-appearance",title:"Toggle System Appearance",detail:"System",symbol:"circle.lefthalf.filled",keywords:"dark light mode theme",action:.toggleSystemAppearance)] + SwitcharooAppearance.allCases.map { mode in
            LauncherResult(id:"appearance:"+mode.rawValue,title:"Switcharoo Appearance: "+mode.title,detail:"Appearance",symbol:mode == .system ? "desktopcomputer" : mode == .dark ? "moon" : "sun.max",keywords:"theme dark light system automatic",action:.appearance(mode))
        }
    }
    private var toolResults: [LauncherResult] { [
        .init(id: "schedule",title: "My Schedule",detail: "Calendar",symbol: "calendar",keywords: "agenda meetings",action: .route(.schedule)),
        .init(id: "calculator-history",title: "Calculator History",detail: "Math",symbol: "clock",keywords: "calculations pinned",action: .route(.calculatorHistory)),
        .init(id: "calculator-settings",title: "Calculator Settings",detail: "Math",symbol: "slider.horizontal.3",keywords: "rem automatic units",action: .route(.calculatorSettings)),
        .init(id: "calculator",title: "Calculator",detail: "Math",symbol: "function",keywords: "calculate math graph units conversion",action: .route(.calculator)),
        .init(id: "timers",title: "Timers",detail: "Timer",symbol: "timer",keywords: "countdown focus",action: .route(.timers)),
        .init(id:"settings",title:"Switcharoo Settings",detail:"Settings",symbol:"gearshape",keywords:"preferences appearance startup keyboard",action:.route(.settings)),
        .init(id: "window-controls",title: "Window Management",detail: "Settings",symbol: "slider.horizontal.3",keywords: "window management shortcuts settings preferences",action: .route(.windowControls))
    ] }
    @Published var selectedID = "schedule"
    @Published var route: LauncherRoute = .search
    @Published var focusGeneration = 0
    @Published var message = ""
    var didChangeRoute: (() -> Void)?
    var recentApps: [String] = UserDefaults.standard.stringArray(forKey: "launcher.recent-apps") ?? [] { didSet { cachedConfig = nil } }
    func navigate(_ route: LauncherRoute) { if self.route != route { self.route = route }; if !message.isEmpty { message = "" }; focusGeneration += 1; didChangeRoute?() }
    func back() { if route == .search { LauncherController.shared.dismiss(restoreFocus: true) } else { navigate(route == .windowControls ? .settings : .search) } }
    func results(apps: [LaunchableApplication],config: WMConfiguration) -> [LauncherResult] {
        prepareResults(apps:apps,config:config)
        let trimmed = query.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.isEmpty { return cachedRanked }
        if cachedQuery == trimmed { return cachedMatches }
        cachedQuery = trimmed
        if let url = LauncherSearch.webURL(trimmed) {
            cachedMatches = [.init(id:"open-url",title:"Open URL",detail:url.absoluteString,symbol:"globe",action:.openURL(url))]
        } else {
            cachedMatches = LauncherSearch.matchingIndices(trimmed,in:cachedRanked.map { ($0.title,$0.keywords) }).map { cachedRanked[$0] }
        }
        return cachedMatches
    }
    func choose(_ result: LauncherResult) {
        if case .openURL = result.action { /* Transient URLs are not saved in launch history. */ }
        else { usage.record(result.id); saveUsage() }
        switch result.action {
        case .openURL(let url):
            LauncherController.shared.dismiss()
            if !NSWorkspace.shared.open(url) { LauncherController.shared.show(); message = "Could not open URL in the default browser." }
        case .route(let route): navigate(route)
        case .appearance(let mode): mode.save(); focusGeneration += 1
        case .toggleSystemAppearance:
            SystemAppearance.toggle { error in
                if let error { self.message = error } else if LauncherController.shared.isVisible && NSApp.isActive { LauncherController.shared.dismiss(restoreFocus:true) }
            }
        case .command(let id): WindowManager.shared.executeAction(id); LauncherController.shared.dismiss()
        case .application(let app):
            recentApps.removeAll { $0 == app.id }; recentApps.insert(app.id,at: 0); recentApps = Array(recentApps.prefix(20))
            UserDefaults.standard.set(recentApps,forKey: "launcher.recent-apps")
            LauncherController.shared.dismiss()
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: app.url,configuration: configuration) { _,error in
                if let error { DispatchQueue.main.async { LauncherController.shared.show(); self.message = error.localizedDescription } }
            }
        }
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { LauncherController.shared.model.back() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? WMRecorderButton,recorder.recording { recorder.keyDown(with:event); return true }
        if isKeyWindow,AppShortcuts.shared.matches(.settings,event:event) { LauncherController.shared.showSettings(); return true }
        if isKeyWindow,LauncherController.shared.model.handleShortcut(event) { return true }
        return super.performKeyEquivalent(with:event)
    }
}
final class LauncherController: NSObject, NSWindowDelegate {
    static let shared = LauncherController()
    let model = LauncherModel()
    let calculator = CalculatorModel()
    private var panel: LauncherPanel?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var catalogSubscription: AnyCancellable?
    let previousFocus = LauncherFocus()
    private var demo = false
    private let guides = LauncherGuides()
    private var dragging = false
    private var dragOrigin: (mouse:CGPoint,frame:CGRect)?
    private var settingFrame = false
    private var barFrame: CGRect?
    private var dragEndMonitor: Any?
    private var dragEndTimer: Timer?
    private var position: LauncherPosition? = {
        guard let data = launcherPreferences.defaults.data(forKey:"launcher.position") else { return nil }
        return try? JSONDecoder().decode(LauncherPosition.self,from:data)
    }()
    private(set) var actionTarget: WMTarget?
    private(set) var hotkeyIssue: String?
    var isVisible: Bool { panel?.isVisible == true }
    override init() {
        super.init()
        model.didChangeRoute = { [weak self] in self?.resize() }; calculator.didChange = { [weak self] in self?.resize() }
        catalogSubscription = Publishers.CombineLatest3(ApplicationCatalog.shared.$applications,WindowManager.shared.$configuration,ApplicationCatalog.shared.$runningPaths)
            .receive(on:DispatchQueue.main).sink { [weak self] apps,config,_ in
                self?.model.prepareResults(apps:apps,config:config)
            }
    }
    func start() {
        ApplicationCatalog.shared.refresh()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,event,_ in
            var id = EventHotKeyID()
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id) == noErr,id.signature == 0x4C4D4F44 else { return OSStatus(eventNotHandledErr) }
            LauncherController.shared.toggle(); return noErr
        },1,&spec,nil,&handler)
        retryShortcut()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            self.prepare(preview:false); self.resize()
            self.panel?.contentView?.layoutSubtreeIfNeeded()
            CalculatorEngine.shared.prewarm()
            switcharooLog("launcher: prewarm=\(String(format: "%.1f",(CACurrentMediaTime()-start)*1000))ms")
        }
    }
    func suspendShortcut() { if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil }
    @objc func retryShortcut() {
        suspendShortcut()
        let key = AppShortcuts.shared.configuration[.launcher]
        let status = RegisterEventHotKey(key.keyCode,key.modifiers,EventHotKeyID(signature: 0x4C4D4F44,id: 1),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&hotkey)
        hotkeyIssue = status == noErr ? nil : "Launcher: shortcut is in use"
        switcharooLog("launcher: shortcut=\(WMRecorderButton.label(key)) registered=\(status == noErr) status=\(status)")
    }
    func showSettings() {
        model.actionItem = nil; model.showingPinPicker = false
        show(.settings)
    }
    @objc func toggle() { if isVisible { dismiss(restoreFocus:true) } else { show() } }
    func show(_ route: LauncherRoute = .search,preview: Bool = false) {
        let start = CACurrentMediaTime()
        if !isVisible {
            model.resetForOpening(); calculator.update("")
            if let app = NSApp.delegate as? App,app.panel?.isVisible == true {
                previousFocus.inherit(from:app.previousFocus)
                actionTarget = previousFocus.applicationPID.map { WMTarget(pid:$0,windowID:nil) }
            } else {
                actionTarget = WindowManager.shared.target()
                previousFocus.capture(fallbackPID:WindowManager.shared.lastExternalPID)
            }
        }
        if let app = NSApp.delegate as? App,app.panel?.isVisible == true { app.dismissPanel() }
        let beforePrepare = CACurrentMediaTime()
        prepare(preview: preview)
        let afterPrepare = CACurrentMediaTime()
        ApplicationCatalog.shared.refresh()
        model.navigate(route); resize()
        let beforeOrder = CACurrentMediaTime()
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        let afterOrder = CACurrentMediaTime()
        panel?.contentView?.layoutSubtreeIfNeeded()
        if route == .search { focusSearch() }
        panel?.displayIfNeeded()
        switcharooLog("launcher: open=\(String(format: "%.1f",(CACurrentMediaTime()-start)*1000))ms compact=\(!model.showingCommands) size=\(panel?.frame.size ?? .zero) prepare=\(String(format:"%.1f",(afterPrepare-beforePrepare)*1000))ms order=\(String(format:"%.1f",(afterOrder-beforeOrder)*1000))ms layout=\(String(format:"%.1f",(CACurrentMediaTime()-afterOrder)*1000))ms")
    }
    private func focusSearch() {
        guard panel?.isVisible == true,panel?.isKeyWindow == true,model.route == .search else { return }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "launcher-search" { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        if let content = panel?.contentView,let field = find(content) { panel?.makeFirstResponder(field) }
    }
    private func prepare(preview: Bool) {
        if panel == nil {
            demo = preview
            let panel = LauncherPanel(contentRect: .init(x: 0,y: 0,width: 700,height: 90),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            panel.title = "Switcharoo Launcher"; panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false; panel.delegate = self
            panel.contentView = LauncherHostingView(rootView: LauncherView(model: model,catalog: .shared,manager: .shared,calculator:calculator,preview: preview))
            self.panel = panel
        }
    }
    func dismiss(restoreFocus: Bool = false) {
        model.actionItem = nil; model.showingPinPicker = false
        calculator.save(); finishDrag()
        if restoreFocus { previousFocus.restore() }
        panel?.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        // Menus, permission prompts and expanded windows can temporarily own
        // focus inside this app. Only dismiss for an actual app switch.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.isVisible,!NSApp.isActive else { return }; self.dismiss()
        }
    }
    func resize() {
        guard let panel,!dragging else { return }
        let savedScreen = position.flatMap { saved in NSScreen.screens.first { Self.displayID($0) == saved.displayID } }
        guard let screen = (panel.isVisible ? panel.screen : savedScreen) ?? NSScreen.main else { return }
        let hasResults = model.showingCommands || !model.query.isEmpty
        let showsCalculation = calculator.hasContent
        let count = hasResults && !showsCalculation && model.route == .search ? model.results(apps: ApplicationCatalog.shared.applications,config: WindowManager.shared.configuration).count : 0
        let contentHeight: Int = showsCalculation ? 148 : (hasResults ? min(8,max(1,count))*40+68 : 0)
        let preferred: CGFloat = model.route == .search ? CGFloat(90+contentHeight) : (model.route == .settings ? 460 : 620)
        let width = min(CGFloat(700),screen.visibleFrame.width-32)
        let barSize = CGSize(width:width,height:90)
        let anchor: CGRect
        if panel.isVisible,let barFrame {
            anchor = CGRect(x:barFrame.midX-width/2,y:barFrame.maxY-90,width:width,height:90)
        } else if let position {
            anchor = position.frame(size:barSize,on:screen.visibleFrame)
        } else {
            let top = screen.visibleFrame.maxY-min(180,screen.visibleFrame.height*0.2)
            anchor = CGRect(x:screen.visibleFrame.midX-width/2,y:top-90,width:width,height:90)
        }
        let expansion = LauncherExpansion(bar:anchor,preferredHeight:preferred,screen:screen.visibleFrame)
        barFrame = expansion.bar
        if model.expandsUpward != expansion.upward { model.expandsUpward = expansion.upward }
        let frame = expansion.frame
        if panel.frame != frame {
            settingFrame = true
            panel.setFrame(frame,display:true,animate:false)
            settingFrame = false
        }
    }
    private static func displayID(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    func dragBody(translation: CGSize) {
        guard let panel else { return }
        if dragOrigin == nil {
            dragging = true
            let mouse = NSEvent.mouseLocation
            dragOrigin = (CGPoint(x:mouse.x-translation.width,y:mouse.y+translation.height),panel.frame)
            guides.show()
        }
        guard let origin = dragOrigin else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x:origin.frame.minX+mouse.x-origin.mouse.x,y:origin.frame.minY+mouse.y-origin.mouse.y))
        guides.update(frame:composerFrame(in:panel.frame),screen:panel.screen)
    }
    private func composerFrame(in frame: CGRect) -> CGRect {
        CGRect(x:frame.minX,y:model.expandsUpward ? frame.minY : frame.maxY-90,width:frame.width,height:90)
    }
    func endBodyDrag() { finishDrag() }
    func windowDidMove(_ notification: Notification) {
        guard dragging else { return }
        if let panel { guides.update(frame:composerFrame(in:panel.frame),screen:panel.screen) }
        // AppKit's native drag loop can consume mouse-up before local monitors see it.
        if NSEvent.pressedMouseButtons & 1 == 0 { finishDrag() }
    }
    private func finishDrag() {
        dragOrigin = nil; guides.hide(); dragEndTimer?.invalidate(); dragEndTimer = nil
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }; dragEndMonitor = nil
        guard dragging,let panel,let screen = panel.screen else { dragging = false; return }
        dragging = false
        settingFrame = true
        // Snap the composer itself; expanded content must not redefine the anchor.
        let bar = composerFrame(in:panel.frame)
        let snapped = LauncherPlacement.snap(bar,to:screen.visibleFrame)
        barFrame = snapped
        settingFrame = false
        position = LauncherPosition(frame:snapped,screen:screen.visibleFrame,displayID:Self.displayID(screen))
        resize()
        if let data = try? JSONEncoder().encode(position) { launcherPreferences.defaults.set(data,forKey:"launcher.position") }
    }
    /// Uses preview preferences and the production view to verify both growth directions.
    func previewAnchoring() {
        guard demo,let screen = panel?.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        var observations: [[String:Any]] = []
        func capture(_ name: String) {
            self.snapshot(to:URL(fileURLWithPath:"/tmp/switcharoo-anchor-"+name+".png"),dark:false)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
                guard let frame = self.panel?.frame,let bar = self.barFrame else { return }
                observations.append(["state":name,"bar":[bar.minX,bar.minY,bar.width,bar.height],"window":[frame.minX,frame.minY,frame.width,frame.height],"upward":self.model.expandsUpward])
            }
        }
        func place(low: Bool) {
            self.model.query = ""; self.calculator.update(""); self.model.showingCommands = false
            self.barFrame = CGRect(x:bounds.midX-350,y:low ? bounds.minY+70 : bounds.maxY-220,width:700,height:90)
            self.resize()
        }
        place(low:false); capture("compact")
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            self.model.showingCommands = true; self.resize(); capture("down")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            self.model.query = "21 + 21"; self.calculator.update(self.model.query); capture("input")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { place(low:true); capture("low-compact") }
        DispatchQueue.main.asyncAfter(deadline:.now()+4) {
            self.model.showingCommands = true; self.resize(); capture("up")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            self.model.showingCommands = false; self.resize(); capture("collapsed")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+6) {
            if let data = try? JSONSerialization.data(withJSONObject:observations,options:.prettyPrinted) { try? data.write(to:URL(fileURLWithPath:"/tmp/switcharoo-anchor-frames.json")) }
            NSApp.terminate(nil)
        }
    }
    private func captureAlignment(_ view: NSView,name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/switcharoo-alignment-"+name+".png"))
    }
    /// Exercises native editors and real panel handoffs, without posting global keys.
    func runFocusRegression(app: App) {
        var checks: [String:Bool] = [:]
        show(preview:true)
        model.query = ""; model.showingCommands = false; resize()
        model.openActions()
        checks["compact actions have bar context"] = model.actionItem?.id == "launcher-bar"
        checks["bar actions do not open a hidden app"] = LauncherItemAction.actions(for:LauncherModel.barContext,model:model).map(\.id) == ["browse","add-pin","settings","appearance"]
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            app.show(startReversed:false)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
            checks["launcher hidden after Option-Tab handoff"] = !self.isVisible
            checks["Option-Tab owns key window"] = app.panel.isKeyWindow
            checks["Option-Tab editable and selectable"] = app.view.searchField.isEditable && app.view.searchField.isSelectable
            if let editor = app.view.searchField.currentEditor() as? NSTextView {
                checks["Option-Tab owns field editor"] = app.panel.firstResponder === editor
                let rect = app.view.convert(app.panel.convertFromScreen(editor.firstRect(forCharacterRange:NSRange(location:0,length:0),actualRange:nil)),from:nil)
                checks["Option-Tab caret centered in 50-point row"] = abs(rect.midY-25) <= 1
                self.captureAlignment(app.view,name:"option-tab")
                editor.insertText("switcharoo-no-match-8abf",replacementRange:NSRange(location:NSNotFound,length:0))
                checks["typing filters Option-Tab"] = app.view.query == "switcharoo-no-match-8abf" && app.rows.isEmpty
                editor.selectAll(nil); editor.insertText("",replacementRange:NSRange(location:NSNotFound,length:0))
                checks["clearing restores windows"] = app.view.query.isEmpty && !app.rows.isEmpty
                let start = app.selected
                editor.doCommand(by:#selector(NSResponder.moveDown(_:)))
                checks["down arrow selects next window"] = app.rows.isEmpty ? false : app.selected == (start+1)%app.rows.count
                editor.doCommand(by:#selector(NSResponder.moveUp(_:)))
                checks["up arrow selects previous window"] = app.selected == start
            } else { checks["Option-Tab owns field editor"] = false }
            self.show(preview:true)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.9) {
            checks["base switcher hidden after launcher handoff"] = !app.panel.isVisible
            checks["launcher owns its editor"] = self.panel?.isKeyWindow == true && self.panel?.firstResponder is SteadyCaretEditor
            if let panel = self.panel,let editor = panel.firstResponder as? NSTextView,let view = panel.contentView {
                self.captureAlignment(view,name:"main")
                let rect = panel.convertFromScreen(editor.firstRect(forCharacterRange:NSRange(location:0,length:0),actualRange:nil))
                checks["main caret aligns with wand left edge"] = abs(rect.minX-25) <= 1
                checks["search fonts match"] = editor.font?.fontName == app.view.searchField.font?.fontName && editor.font?.pointSize == app.view.searchField.font?.pointSize
                checks["search panels both 700 points"] = panel.frame.width == app.panel.frame.width && panel.frame.width == SwitcharooSearchMetrics.panelWidth
                func searchField(in view: NSView) -> NSView? {
                    if view.identifier?.rawValue == "launcher-search" { return view }
                    return view.subviews.compactMap { searchField(in:$0) }.first
                }
                if let field = searchField(in:view) {
                    checks["search input dimensions match"] = field.frame.size == app.view.searchField.frame.size
                    switcharooLog("search dimensions: main=\(field.frame) option=\(app.view.searchField.frame) mainCaret=\(rect)")
                } else { checks["search input dimensions match"] = false }
                checks["Option-Tab search inset matches main"] = app.view.searchField.frame.minX == SwitcharooSearchMetrics.leading
            }
            self.model.showingCommands = true; self.model.query = "no-result-8abf"; self.model.selectedID = ""
            self.model.openActions()
            checks["no-result actions have bar context"] = self.model.actionItem?.id == "launcher-bar"
            self.model.actionItem = nil; self.model.query = ""; self.model.showingCommands = true
            self.model.selectedID = "schedule"; self.model.openActions()
            checks["visible selection retains item actions"] = self.model.actionItem?.id == "schedule"
            self.model.actionItem = nil; self.dismiss()
            app.show(startReversed:false)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) {
            checks["second Option-Tab opening owns editor"] = app.panel.isKeyWindow && app.view.searchField.currentEditor() === app.panel.firstResponder
            if let editor = app.view.searchField.currentEditor() as? NSTextView { editor.doCommand(by:#selector(NSResponder.cancelOperation(_:))) }
            checks["Escape dismisses Option-Tab"] = !app.panel.isVisible
            func settingsKey(_ window: NSWindow) -> Bool {
                guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:",",charactersIgnoringModifiers:",",isARepeat:false,keyCode:43) else { return false }
                return window.performKeyEquivalent(with:event)
            }
            self.show(preview:true)
            checks["Cmd-comma in main opens app settings"] = self.panel.map(settingsKey) == true && self.model.route == .settings
            self.model.navigate(.windowControls); self.model.back()
            checks["window management is a settings subpage"] = self.model.route == .settings
            app.show(startReversed:false)
            checks["Cmd-comma in Option-Tab opens app settings"] = settingsKey(app.panel) && self.model.route == .settings && !app.panel.isVisible
            app.show(startReversed:false)
            app.quickMode = true; app.view.quickMode = true; app.panel.makeFirstResponder(app.panel)
            checks["Cmd-comma in Command-Tab opens app settings"] = settingsKey(app.panel) && self.model.route == .settings && !app.panel.isVisible
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.7) {
            if let view = self.panel?.contentView { self.captureAlignment(view,name:"settings") }
            let suiteName = "switcharoo.shortcut-test."+UUID().uuidString
            let suite = UserDefaults(suiteName:suiteName)!
            let settings = AppShortcuts(defaults:suite)
            let replacement = WMShortcut(keyCode:17,modifiers:4352)
            settings.update(.settings,to:replacement)
            checks["app shortcut persists across store reload"] = AppShortcuts(defaults:suite).configuration[.settings] == replacement
            settings.update(.launcher,to:replacement)
            checks["duplicate app shortcut rejected without replacement"] = settings.configuration[.launcher] == AppShortcutID.launcher.defaultShortcut && !settings.message.isEmpty
            suite.removePersistentDomain(forName:suiteName)
            if let panel = self.panel,let content = panel.contentView {
                let recorder = WMRecorderButton(frame:CGRect(x:0,y:0,width:160,height:28))
                content.addSubview(recorder)
                var recorded: WMShortcut?
                recorder.changed = { recorded = $0 }
                let click = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                recorder.mouseDown(with:click)
                checks["click starts recording and suspends shortcuts"] = recorder.recording && AppShortcuts.shared.recording
                let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48)!
                _ = panel.performKeyEquivalent(with:key)
                checks["recorded shortcut captures key and modifiers"] = recorded == WMShortcut(keyCode:48,modifiers:256)
                checks["recording completion resumes shortcuts"] = !AppShortcuts.shared.recording
                recorder.mouseDown(with:click)
                let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
                _ = panel.performKeyEquivalent(with:escape)
                checks["Escape cancels recording without changing shortcut"] = recorded == WMShortcut(keyCode:48,modifiers:256) && !recorder.recording
                recorder.mouseDown(with:click)
                _ = panel.makeFirstResponder(content)
                checks["focus loss ends recording"] = !AppShortcuts.shared.recording
                recorder.removeFromSuperview()
            }
            let output: [String:Any] = ["checks":checks,"passed":checks.values.allSatisfy({$0}),"count":checks.count]
            if let data = try? JSONSerialization.data(withJSONObject:output,options:.prettyPrinted) { try? data.write(to:URL(fileURLWithPath:"/tmp/switcharoo-focus-regression.json")) }
            NSApp.terminate(nil)
        }
    }
    func previewInteractions() {
        let savedUsage = model.usage
        let savedAppearance = NSApp.appearance
        var observations: [String:Any] = [:]
        func capture(_ name: String) {
            for (index,window) in NSApp.windows.filter({$0.isVisible}).enumerated() {
                guard let view = window.contentView,let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { continue }
                view.cacheDisplay(in:view.bounds,to:rep)
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/switcharoo-interaction-"+name+"-"+String(index)+".png"))
            }
        }
        func key(_ chars: String,_ flags: NSEvent.ModifierFlags) -> Bool {
            guard let panel,let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:0) else { return false }
            return panel.performKeyEquivalent(with:event)
        }
        model.usage.pinned = []; model.saveUsage(); model.showingCommands = false; resize(); focusSearch()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            observations["steadyEditor"] = self.panel?.firstResponder is SteadyCaretEditor
            observations["compactHeight"] = self.panel?.frame.height
            capture("caret-a")
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { capture("caret-b") }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {
            self.model.showingCommands = true; self.resize()
            let items = self.model.results(apps:ApplicationCatalog.shared.applications,config:WindowManager.shared.configuration)
            if let item = items.first(where:{ if case .application = $0.action { return true }; return false }) { self.model.selectedID = item.id }
            observations["commandKHandled"] = key("k",.command)
            observations["actionContext"] = self.model.actionItem?.title
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { capture("actions") }
        DispatchQueue.main.asyncAfter(deadline:.now()+2.5) {
            self.model.actionItem = nil
            observations["pinShortcutHandled"] = key("p",[.command,.shift])
            observations["pinnedSelected"] = self.model.usage.pinned.contains(self.model.selectedID)
            self.model.showingPinPicker = true
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { capture("pins") }
        DispatchQueue.main.asyncAfter(deadline:.now()+3.5) {
            self.model.showingPinPicker = false
            let saved = SwitcharooAppearance.saved
            SwitcharooAppearance.dark.apply(); observations["darkApplied"] = Theme.isDark
            SwitcharooAppearance.light.apply(); observations["lightApplied"] = !Theme.isDark
            SwitcharooAppearance.system.apply(); observations["systemInherits"] = NSApp.appearance == nil
            observations["themePreferenceUnchanged"] = saved == SwitcharooAppearance.saved
            NSApp.appearance = savedAppearance
            self.model.navigate(.schedule)
            self.panel?.appearance = NSAppearance(named:.aqua)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { capture("schedule-light") }
        DispatchQueue.main.asyncAfter(deadline:.now()+4.5) {
            self.model.usage = savedUsage; self.model.saveUsage()
            if let data = try? JSONSerialization.data(withJSONObject:observations,options:.prettyPrinted) { try? data.write(to:URL(fileURLWithPath:"/tmp/switcharoo-interactions.json")) }
            NSApp.terminate(nil)
        }
    }
    func snapshot(to url: URL,dark: Bool) {
        panel?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [weak self] in
            guard let view = self?.panel?.contentView,let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds,to: rep)
            try? rep.representation(using: .png,properties: [:])?.write(to: url)
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var catalog: ApplicationCatalog
    @ObservedObject var manager: WindowManager
    @ObservedObject var calculator: CalculatorModel
    let preview: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    init(model: LauncherModel,catalog: ApplicationCatalog,manager: WindowManager,calculator: CalculatorModel,preview: Bool) {
        self.model = model; self.catalog = catalog; self.manager = manager; self.calculator = calculator; self.preview = preview
    }
    private var results: [LauncherResult] { model.results(apps: catalog.applications,config: manager.configuration) }
    var body: some View {
        VStack(spacing: 0) {
            if model.route != .search && model.route != .windowControls && model.route != .schedule && model.route != .settings { toolBar }
            switch model.route {
            case .search:
                if model.expandsUpward {
                    if hasSearchContent { searchContent; Divider() }
                }
                composer
                if !model.expandsUpward {
                    if hasSearchContent { Divider(); searchContent }
                }
            case .settings: SwitcharooSettingsView(model:model)
            case .schedule: LauncherScheduleContent(preview: preview)
            case .timers: LauncherTimersContent(preview: preview)
            case .calculator: CalculatorWorkspaceView(initialQuery:model.query)
            case .calculatorHistory: CalculatorHistoryView()
            case .calculatorSettings: CalculatorSettingsView()
            case .windowControls: WMPreferencesView(manager: manager,embedded: true,onBack: { model.back() })
            }
        }.font(SwitcharooTypography.ui(size: 14)).background(ToolStyle.background(scheme)).clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.09),lineWidth: 1) }
            .tint(ToolStyle.accent(scheme)).onAppear { searchFocused = model.route == .search }
            .onChange(of: model.focusGeneration) { _,_ in searchFocused = model.route == .search }
            .onChange(of: model.query) { _,_ in model.selectedID = results.first?.id ?? ""; calculator.update(LauncherSearch.webURL(model.query) == nil ? model.query : ""); LauncherController.shared.resize() }
            .onChange(of: catalog.applications.count) { _,_ in LauncherController.shared.resize() }
            .onExitCommand(perform:exitSearch)
            .alert("Switcharoo",isPresented:Binding(get:{ !model.message.isEmpty },set:{ if !$0 { model.message = "" } })) { Button("OK") { model.message = "" } } message: { Text(model.message) }
            .popover(item:$model.actionItem,arrowEdge:.bottom) { item in
                LauncherActionsPopover(item:item,model:model)
                    .onDisappear { model.focusGeneration += 1 }
            }
    }
    private var hasSearchContent: Bool { calculator.hasContent || model.showingCommands || !model.query.isEmpty }
    @ViewBuilder private var searchContent: some View {
        if calculator.hasContent {
            ScrollView { CalculatorAnswerView(model:calculator,openGraph:{ model.navigate(.calculator) },replaceQuery:{ model.query = $0 }) }
        } else { resultList }
    }
    private func exitSearch() { if model.route == .search && !model.query.isEmpty { model.query = "" } else if model.route == .search && model.showingCommands { model.showingCommands = false; LauncherController.shared.resize() } else { model.back() } }
    @ViewBuilder private func resultIcon(_ result: LauncherResult,size: CGFloat) -> some View {
        if case .application(let app) = result.action { Image(nsImage: catalog.icon(app)).resizable().frame(width: size,height: size) }
        else { Image(systemName: result.symbol).font(SwitcharooTypography.ui(size: size-3,weight: .light)).frame(width: size,height: size) }
    }
    @ViewBuilder private func pinAction(_ result: LauncherResult) -> some View {
        if case .openURL = result.action { EmptyView() }
        else if model.usage.pinned.contains(result.id) { Button("Unpin from bar") { model.togglePin(result.id) } }
        else { Button(model.usage.pinned.count < 3 ? "Pin to bar" : "3 items pinned") { model.togglePin(result.id) }.disabled(model.usage.pinned.count >= 3) }
    }
    private var resultList: some View {
        VStack(spacing:0) {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.expandsUpward ? Array(results.reversed()) : results) { result in
                        Button { model.selectedID = result.id; model.choose(result) } label: {
                            HStack(spacing: 12) {
                                resultIcon(result,size: 20)
                                Text(result.title).font(SwitcharooTypography.ui(size: 13)).lineLimit(1)
                                Spacer()
                                if case .appearance(let mode) = result.action,mode == SwitcharooAppearance.saved { Image(systemName:"checkmark").font(.system(size:10)).foregroundStyle(.secondary) }
                                if model.usage.pinned.contains(result.id) { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                                Text(result.detail).font(SwitcharooTypography.ui(size: 12)).foregroundStyle(ToolStyle.secondary(scheme)).lineLimit(1).truncationMode(.middle)
                            }.foregroundStyle(.primary).padding(.horizontal,14).frame(height: 38)
                                .background(model.selectedID == result.id ? Color.primary.opacity(0.065) : .clear,in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        }.buttonStyle(LauncherHoverStyle(horizontal:0,vertical:0,radius:10)).id(result.id).contextMenu { pinAction(result) }
                    }
                    if results.isEmpty { Text("No results").foregroundStyle(ToolStyle.secondary(scheme)).padding(20) }
                }.padding(.horizontal,10)
            }.onChange(of: model.selectedID) { _,id in proxy.scrollTo(id) }
                .onAppear { proxy.scrollTo(model.selectedID,anchor:model.expandsUpward ? .bottom : .top) }
                // Keep this outside the scrolling content: scrollTo must not remove the inset.
                .padding(.vertical,16)
        }
        Divider()
        HStack(spacing:10) {
            Spacer()
            Text(selectedPrimaryTitle).foregroundStyle(.secondary)
            LauncherKeycap(text:"↩")
            Button { model.openActions() } label: {
                HStack(spacing:7) { Text("Actions"); LauncherKeycap(text:"⌘ K") }
            }.buttonStyle(LauncherHoverStyle(horizontal:6,vertical:4)).disabled(results.isEmpty)
        }.font(SwitcharooTypography.ui(size:11)).padding(.horizontal,18).frame(height:35)
        }
    }
    private var selectedPrimaryTitle: String {
        guard let item = results.first(where:{$0.id == model.selectedID}) ?? results.first else { return "Open" }
        return LauncherItemAction.actions(for:item,model:model).first?.title ?? "Open"
    }
    private var pinnedItems: [LauncherResult] { model.quickResults(apps:catalog.applications,config:manager.configuration) }
    private var composer: some View {
        VStack(spacing:0) {
            VStack(spacing:0) {
                LauncherDragArea().frame(height:10)
                LauncherSearchField(text:$model.query,focusGeneration:model.focusGeneration,move:move,submit:{ modifiers in
                    if modifiers.contains(.command),calculator.hasContent { copyCalculationAndDismiss(raw:!modifiers.contains(.shift),includeQuery:modifiers.contains(.shift)) }
                    else if let event = NSApp.currentEvent,model.handleShortcut(event) { }
                    else { chooseSelected() }
                },escape:exitSearch).frame(height:SwitcharooSearchMetrics.fieldHeight).padding(.leading,SwitcharooSearchMetrics.leading).padding(.trailing,SwitcharooSearchMetrics.trailing)
                LauncherDragArea().frame(height:10)
            }.frame(height:SwitcharooSearchMetrics.rowHeight)
            HStack(spacing:6) {
                Button { model.showingCommands.toggle(); model.selectedID = results.first?.id ?? ""; model.focusGeneration += 1; LauncherController.shared.resize() } label: {
                    Image(nsImage:LauncherIcons.wand).renderingMode(.template).resizable().frame(width:16,height:16).frame(width:28,height:28)
                }.buttonStyle(LauncherHoverStyle()).help("Commands · ↓").accessibilityLabel("Browse commands")
                Button { model.showingPinPicker.toggle() } label: {
                    Image(systemName:"plus").font(SwitcharooTypography.ui(size:16,weight:.light)).frame(width:28,height:28)
                }.buttonStyle(LauncherHoverStyle()).help("Pin an item").accessibilityLabel("Pin an item")
                    .popover(isPresented:$model.showingPinPicker,arrowEdge:.bottom) {
                        LauncherPinPicker(model:model,catalog:catalog,manager:manager)
                            .onDisappear { model.focusGeneration += 1 }
                    }
                ForEach(pinnedItems) { result in
                    Button { model.choose(result) } label: {
                        HStack(spacing:6) { resultIcon(result,size:15); Text(result.title).font(SwitcharooTypography.ui(size:12)).lineLimit(1) }.foregroundStyle(.secondary)
                    }.buttonStyle(LauncherHoverStyle(horizontal:6,vertical:5)).contextMenu { pinAction(result) }
                }
                LauncherDragArea().frame(maxWidth:.infinity,maxHeight:.infinity)
                Button(action:chooseSelected) {
                    Image(systemName:calculator.answer == nil ? "arrow.up" : "doc.on.doc").font(SwitcharooTypography.ui(size:14,weight:.medium)).frame(width:28,height:28)
                        .foregroundStyle(scheme == .dark ? Color.black : .white).background(scheme == .dark ? Color.white : .black,in:Circle())
                }.buttonStyle(LauncherHoverStyle()).disabled(calculator.hasContent && !calculator.canCopy)
                    .accessibilityLabel(calculator.answer != nil ? "Copy calculation" : "Open selected result")
            }.padding(.horizontal,18).padding(.bottom,10).frame(height:40)
        }.frame(height:90)
    }
    private var toolBar: some View {
        HStack(spacing: 12) {
            Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 28,height: 32) }.buttonStyle(LauncherHoverStyle()).help("Back · Esc")
            Text(model.route.title).font(SwitcharooTypography.ui(size: 14,weight: .medium))
            LauncherDragArea().frame(maxWidth:.infinity,maxHeight:.infinity)
        }.padding(.horizontal,18).frame(height: 54)
    }
    private func copyCalculationAndDismiss(raw: Bool = false,includeQuery: Bool = false) {
        guard calculator.canCopy else { return }
        calculator.copy(raw:raw,includeQuery:includeQuery)
        LauncherController.shared.dismiss(restoreFocus:true)
    }
    private func chooseSelected() {
        if calculator.hasContent { copyCalculationAndDismiss(); return }
        if !model.showingCommands && model.query.isEmpty { model.showingCommands = true; model.selectedID = results.first?.id ?? ""; LauncherController.shared.resize(); return }
        if let result = results.first(where: { $0.id == model.selectedID }) ?? results.first { model.choose(result) }
    }
    private func move(_ physicalOffset: Int) {
        let offset = model.expandsUpward ? -physicalOffset : physicalOffset
        guard !results.isEmpty else { return }
        if !model.showingCommands && model.query.isEmpty { model.showingCommands = true; model.selectedID = (offset > 0 ? results.first : results.last)?.id ?? ""; LauncherController.shared.resize(); return }
        let index = results.firstIndex { $0.id == model.selectedID } ?? 0
        model.selectedID = results[(index+offset+results.count)%results.count].id
    }
}

private struct LauncherScheduleContent: View {
    @State private var model: ScheduleModel
    init(preview: Bool) { _model = State(initialValue: preview ? ScheduleModel.preview() : .shared) }
    var body: some View { ScheduleView(model:model,embedded:true,onBack:{ LauncherController.shared.model.back() }) }
}
private struct LauncherTimersContent: View {
    @State private var model: CountdownModel
    init(preview: Bool) { _model = State(initialValue: preview ? CountdownModel.sample() : .shared) }
    var body: some View { CountdownView(model:model,embedded:true) }
}
private final class LauncherHostingView: NSHostingView<LauncherView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

private enum LauncherIcons {
    static let wand: NSImage = {
        guard let url = Bundle.main.url(forResource:"wand-sparkles",withExtension:"svg"),let image = NSImage(contentsOf:url) else { return NSImage(size:CGSize(width:24,height:24)) }
        image.isTemplate = true; return image
    }()
}

struct LauncherKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(SwitcharooTypography.ui(size:11)).foregroundStyle(.secondary)
            .padding(.horizontal,6).frame(minWidth:22,minHeight:21)
            .background(Color.primary.opacity(0.065),in:RoundedRectangle(cornerRadius:5))
    }
}
struct LauncherItemAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let shortcut: String
    var enabled = true
    let run: () -> Void
    static func actions(for item: LauncherResult,model: LauncherModel) -> [Self] {
        if item.id == "launcher-bar" {
            return [
                .init(id:"browse",title:"Browse Commands",symbol:"list.bullet",key:"",modifiers:[],shortcut:"",run:{ model.showingCommands = true; model.selectedID = model.results(apps:ApplicationCatalog.shared.applications,config:WindowManager.shared.configuration).first?.id ?? ""; model.focusGeneration += 1; LauncherController.shared.resize() }),
                .init(id:"add-pin",title:"Pin an Item",symbol:"plus",key:"",modifiers:[],shortcut:"",run:{ DispatchQueue.main.async { model.showingPinPicker = true } }),
                .init(id:"settings",title:"Switcharoo Settings",symbol:"gearshape",key:"",modifiers:[],shortcut:WMRecorderButton.label(AppShortcuts.shared.configuration[.settings]),run:{ model.navigate(.settings) }),
                .init(id:"appearance",title:"Toggle System Appearance",symbol:"circle.lefthalf.filled",key:"",modifiers:[],shortcut:"",run:{ model.choose(.init(id:"system-appearance",title:"Toggle System Appearance",detail:"System",symbol:"circle.lefthalf.filled",action:.toggleSystemAppearance)) })
            ]
        }
        let title: String
        switch item.action {
        case .openURL: title = "Open URL"
        case .application: title = "Open Application"
        case .toggleSystemAppearance: title = "Toggle Appearance"
        case .appearance: title = "Use Appearance"
        case .command: title = "Run Command"
        case .route: title = "Open"
        }
        var actions: [Self] = [.init(id:"open",title:title,symbol:"arrow.up.right",key:"\r",modifiers:[],shortcut:"↩",run:{ model.choose(item) })]
        if case .application(let app) = item.action {
            actions += [
                .init(id:"reveal",title:"Show in Finder",symbol:"folder",key:"\r",modifiers:.command,shortcut:"⌘ ↩",run:{
                    LauncherController.shared.dismiss(); NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }),
                .init(id:"contents",title:"Show Package Contents",symbol:"shippingbox",key:"\r",modifiers:[.command,.option],shortcut:"⌥ ⌘ ↩",run:{
                    LauncherController.shared.dismiss(); NSWorkspace.shared.open(app.url.appendingPathComponent("Contents",isDirectory:true))
                }),
                .init(id:"copy-path",title:"Copy Path",symbol:"doc.on.doc",key:"c",modifiers:[.command,.option],shortcut:"⌥ ⌘ C",run:{
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.url.path,forType:.string)
                })
            ]
        }
        if case .command = item.action {
            actions.append(.init(id:"configure",title:"Configure Window Shortcuts",symbol:"slider.horizontal.3",key:"",modifiers:[],shortcut:"",run:{ model.navigate(.windowControls) }))
        }
        if case .openURL(let url) = item.action {
            actions.append(.init(id:"copy-url",title:"Copy URL",symbol:"doc.on.doc",key:"c",modifiers:[.command,.option],shortcut:"⌥ ⌘ C",run:{
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string)
            }))
            return actions
        }
        let pinned = model.usage.pinned.contains(item.id)
        actions.append(.init(id:"pin",title:pinned ? "Unpin from Bar" : "Pin to Bar",symbol:pinned ? "pin.slash" : "pin",key:"p",modifiers:[.command,.shift],shortcut:"⇧ ⌘ P",enabled:pinned || model.usage.pinned.count < 3,run:{ model.togglePin(item.id) }))
        return actions
    }
}
private struct LauncherActionsPopover: View {
    @Environment(\.colorScheme) private var scheme
    let item: LauncherResult
    @ObservedObject var model: LauncherModel
    @State private var query = ""
    @State private var selected = "open"
    @FocusState private var focused: Bool
    private var actions: [LauncherItemAction] { LauncherItemAction.actions(for:item,model:model).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text(item.title).font(SwitcharooTypography.ui(size:12,weight:.medium)).foregroundStyle(.secondary).lineLimit(1).padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing:2) {
                        ForEach(actions) { action in
                            Button { perform(action) } label: {
                                HStack(spacing:12) {
                                    Image(systemName:action.symbol).frame(width:20)
                                    Text(action.title)
                                    Spacer(minLength:10)
                                    if !action.shortcut.isEmpty { LauncherKeycap(text:action.shortcut) }
                                }.font(SwitcharooTypography.ui(size:13)).padding(.horizontal,12).frame(height:38)
                                    .foregroundStyle(action.enabled ? Color.primary : Color.secondary)
                                    .background(selected == action.id ? Color.primary.opacity(0.075) : .clear,in:RoundedRectangle(cornerRadius:9))
                                    .contentShape(Rectangle())
                            }.buttonStyle(LauncherHoverStyle(radius:9)).disabled(!action.enabled).id(action.id)
                                .keyboardShortcut(action.modifiers.isEmpty ? nil : KeyboardShortcut(KeyEquivalent(action.key.first ?? "\r"),modifiers:eventModifiers(action.modifiers)))
                        }
                        if actions.isEmpty { Text("No actions").foregroundStyle(.secondary).padding(16) }
                    }.padding(.horizontal,8)
                }.frame(height:CGFloat(min(7,max(1,actions.count))*40+8))
                    .onChange(of:selected) { _,id in proxy.scrollTo(id) }
            }
            Divider()
            TextField("Search actions…",text:$query).textFieldStyle(.plain).font(SwitcharooTypography.ui(size:14)).focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { if let action = actions.first(where:{$0.id == selected}) { perform(action) } }
                .padding(.horizontal,16).frame(height:50)
        }.frame(width:350).background(ToolStyle.background(scheme))
            .onAppear { selected = actions.first(where:{$0.enabled})?.id ?? ""; focused = true }
            .onChange(of:query) { _,_ in selected = actions.first(where:{$0.enabled})?.id ?? "" }
            .onExitCommand { model.actionItem = nil }
            .background { Button("") { model.actionItem = nil }.keyboardShortcut("k",modifiers:.command).hidden().accessibilityHidden(true) }
    }
    private func perform(_ action: LauncherItemAction) {
        guard action.enabled else { return }; model.actionItem = nil; action.run()
    }
    private func move(_ delta: Int) {
        let enabled = actions.filter(\.enabled); guard !enabled.isEmpty else { return }
        let index = enabled.firstIndex(where:{$0.id == selected}) ?? (delta > 0 ? -1 : 0)
        selected = enabled[(index+delta+enabled.count)%enabled.count].id
    }
    private func eventModifiers(_ flags: NSEvent.ModifierFlags) -> SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}
private struct LauncherPinPicker: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: LauncherModel
    @ObservedObject var catalog: ApplicationCatalog
    @ObservedObject var manager: WindowManager
    @State private var query = ""
    @State private var selected = ""
    @FocusState private var focused: Bool
    private var items: [LauncherResult] { model.pinCandidates(apps:catalog.applications,config:manager.configuration).filter { query.isEmpty || LauncherSearch.score(query,in:$0.title,keywords:$0.keywords) != nil } }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                TextField("Pin an item…",text:$query).textFieldStyle(.plain).focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onSubmit { if let item = items.first(where:{$0.id == selected}) { model.togglePin(item.id) } }
                Text("\(model.usage.pinned.count)/3").foregroundStyle(.secondary).font(SwitcharooTypography.ui(size:11))
            }.padding(.horizontal,16).frame(height:50)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(items) { item in
                            let pinned = model.usage.pinned.contains(item.id)
                            Button { selected = item.id; model.togglePin(item.id) } label: {
                                HStack(spacing:10) {
                                    if case .application(let app) = item.action { Image(nsImage:catalog.icon(app)).resizable().frame(width:18,height:18) }
                                    else { Image(systemName:item.symbol).frame(width:18,height:18) }
                                    Text(item.title).lineLimit(1)
                                    Spacer()
                                    if pinned { Image(systemName:"checkmark").font(SwitcharooTypography.ui(size:12)) }
                                }.padding(.horizontal,10).frame(height:36).contentShape(Rectangle())
                                    .background(selected == item.id ? Color.primary.opacity(0.065) : .clear,in:RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(LauncherHoverStyle()).disabled(!pinned && model.usage.pinned.count >= 3).id(item.id)
                        }
                        if items.isEmpty { Text("No results").foregroundStyle(.secondary).padding(16) }
                    }.padding(8)
                }.frame(height:280).onChange(of:selected) { _,id in proxy.scrollTo(id) }
            }
        }.font(SwitcharooTypography.ui(size:13)).frame(width:320).background(ToolStyle.background(scheme))
            .onAppear { focused = true; selected = items.first?.id ?? "" }
            .onChange(of:query) { _,_ in selected = items.first?.id ?? "" }
            .onExitCommand { model.showingPinPicker = false }
    }
    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where:{$0.id == selected}) ?? 0
        selected = items[(index+delta+items.count)%items.count].id
    }
}

extension LauncherController {
    func runResponsiveness() {
        let launcher = self
        CalculatorEngine.shared.prewarm()
        launcher.show(preview:true)
        Task { @MainActor in
            for _ in 0..<100 where ApplicationCatalog.shared.refreshedAt == nil { try? await Task.sleep(nanoseconds:50_000_000) }
            launcher.model.query = "finder"
            try? await Task.sleep(nanoseconds:150_000_000)
            let matches = launcher.model.results(apps:ApplicationCatalog.shared.applications,config:WindowManager.shared.configuration)
            let finder = matches.contains { if case .application(let app) = $0.action { return app.bundleID == "com.apple.finder" }; return false }
            @MainActor func capture(_ name: String) {
                guard let view = launcher.panel?.contentView else { return }
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
                view.cacheDisplay(in:view.bounds,to:rep)
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/switcharoo-responsiveness-"+name+".png"))
            }
            capture("finder")
            var elapsed: [Double] = []
            for _ in 0..<5 {
                launcher.model.query = ""
                try? await Task.sleep(nanoseconds:50_000_000)
                let start = CACurrentMediaTime()
                launcher.model.query = "now"
                for _ in 0..<100 {
                    try? await Task.sleep(nanoseconds:10_000_000)
                    if launcher.calculator.canCopy && launcher.calculator.evaluatedQuery == "now" { break }
                }
                launcher.panel?.contentView?.layoutSubtreeIfNeeded()
                launcher.panel?.displayIfNeeded()
                elapsed.append((CACurrentMediaTime()-start)*1000)
            }
            capture("now")
            let nowResult = launcher.calculator.answer?.value ?? ""
            launcher.model.query = "https://example.com/a?q=one%20two#part"
            try? await Task.sleep(nanoseconds:50_000_000)
            let urlItem = launcher.model.selectedVisibleResult
            let urlSelected: Bool
            if case .openURL(let url) = urlItem?.action { urlSelected = url.absoluteString == launcher.model.query } else { urlSelected = false }
            let urlActions = urlItem.map { LauncherItemAction.actions(for:$0,model:launcher.model).map(\.title) } ?? []
            capture("url")
            let output: [String:Any] = ["finderInCompletedCatalog":finder,"nowResult":nowResult,"queryToDisplayMilliseconds":elapsed,"medianMilliseconds":elapsed.sorted()[elapsed.count/2],"urlSelected":urlSelected,"urlClearsCalculator":!launcher.calculator.hasContent && !launcher.calculator.canCopy,"urlActions":urlActions]
            if let data = try? JSONSerialization.data(withJSONObject:output,options:.prettyPrinted) { try? data.write(to:URL(fileURLWithPath:"/tmp/switcharoo-responsiveness.json")) }
            launcher.dismiss(restoreFocus:true)
            NSApp.terminate(nil)
        }
    }
}
