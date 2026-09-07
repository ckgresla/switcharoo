import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Combine

struct WMTarget {
    let pid: pid_t
    let windowID: CGWindowID?
}
struct WMOutcome {
    var message: String
    var milliseconds: Double
    var failed: Bool
}
private struct WMHistory {
    var undo: [CGRect] = []
    var redo: [CGRect] = []
    var lastFrame: CGRect?
    var lastCommand: String?
    var cycle = 0
    var touched = Date()
}

// A separate serial executor owns all AX operations and window history. No
// accessibility calls, disk I/O, or geometry work run on the keyboard tap.
final class WMExecutor {
    private let queue = DispatchQueue(label: "systems.wafer.switcharoo.window-moves", qos: .userInteractive)
    private var history: [String: WMHistory] = [:]
    private let lock = NSLock()
    private var pending = 0
    private let bridge: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
              p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
        return .init(origin: p, size: s)
    }
    private func window(_ target: WMTarget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let id = target.windowID, id != 0 {
            guard let windows = Self.value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
            return windows.first { window in
                var candidate: CGWindowID = 0
                return bridge?(window, &candidate) == .success && candidate == id
            }
        }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = Self.value(app, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }
    private func identity(_ window: AXUIElement, pid: pid_t) -> String? {
        var id: CGWindowID = 0
        guard bridge?(window, &id) == .success, id != 0 else { return nil }
        // The process launch time prevents history being inherited after pid reuse.
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? 0
        return "\(pid):\(launch):\(id)"
    }
    func enqueue(command: WMCommand, target: WMTarget, screens: [WMScreen], cursor: CGPoint, config: WMConfiguration, completion: @escaping (WMOutcome) -> Void) {
        if target.pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { completion(NativeWindowMoves.shared.perform(command,target: target,screens: screens,cursor: cursor,config: config)) }
            return
        }
        lock.lock()
        // Never accumulate an unbounded key-repeat backlog behind a hung app.
        if pending >= 4 { lock.unlock(); return }
        pending += 1
        lock.unlock()
        let submitted = DispatchTime.now().uptimeNanoseconds
        queue.async {
            let result = self.perform(command, target: target, screens: screens, cursor: cursor, config: config)
            let ms = Double(DispatchTime.now().uptimeNanoseconds-submitted)/1_000_000
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
            DispatchQueue.main.async { completion(.init(message: result.0, milliseconds: ms, failed: result.1)) }
        }
    }
    private func perform(_ command: WMCommand, target: WMTarget, screens: [WMScreen], cursor: CGPoint, config: WMConfiguration) -> (String, Bool) {
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return ("Choose a window outside Switcharoo.", true) }
        guard AXIsProcessTrusted() else { return ("Allow Accessibility access in System Settings to move windows.", true) }
        guard let window = window(target), Self.value(window, kAXRoleAttribute) as? String == kAXWindowRole,
              Self.value(window, kAXSubroleAttribute) as? String != kAXSystemDialogSubrole else { return ("No movable window in the selected app.", true) }
        AXUIElementSetMessagingTimeout(window, 0.2)
        if command.operation == .fullscreen {
            let full = Self.value(window, "AXFullScreen") as? Bool ?? false
            let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, full ? kCFBooleanFalse : kCFBooleanTrue)
            return result == .success ? (full ? "Left fullscreen" : "Entered fullscreen", false) : ("This window does not support fullscreen.", true)
        }
        guard Self.value(window, "AXFullScreen") as? Bool != true else { return ("Leave fullscreen before resizing this window.", true) }
        guard let before = Self.rect(window), let source = WMGeometry.screen(for: before, screens: screens) else { return ("Could not read this window's bounds or display.", true) }
        var positionable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionable) == .success, positionable.boolValue else { return ("This window cannot be moved.", true) }
        var p = command.placement
        if command.operation == .nextDisplay { p.display = .next; p.displayID = nil }
        if command.operation == .previousDisplay { p.display = .previous; p.displayID = nil }
        var destination = WMGeometry.destination(p, source: source, screens: screens, cursor: cursor)
        let key = identity(window, pid: target.pid)
        var record = key.flatMap { history[$0] } ?? WMHistory()
        // Manual movement ends the previous placement sequence, including redo.
        if let last = record.lastFrame, !WMGeometry.near(last, before) {
            record.lastCommand = nil; record.cycle = 0; record.redo = []
        }
        var cycle = 0
        if record.lastCommand == command.id, let last = record.lastFrame, WMGeometry.near(last, before) {
            cycle = record.cycle + 1
            if ["left-half", "right-half"].contains(command.id), config.repeatedHalfMovesDisplay,
               (!config.cycleHalves || cycle % 3 == 0) {
                var adjacent = p; adjacent.display = command.id == "left-half" ? .previous : .next
                destination = WMGeometry.destination(adjacent, source: source, screens: screens, cursor: cursor)
            }
        }
        var desired = WMGeometry.frame(command, current: before, source: source.visible, target: destination.visible, config: config, cycle: cycle)
        if command.operation == .undo || command.operation == .redo {
            guard key != nil else { return ("Window history is unavailable for this window.", true) }
            guard let previous = (command.operation == .undo ? record.undo : record.redo).last else { return ("No window move to \(command.operation == .undo ? "undo" : "redo").", true) }
            destination = WMGeometry.screen(for: previous, screens: screens) ?? source
            desired = WMGeometry.clamp(previous, inside: destination.visible)
        }
        if WMGeometry.near(before, desired, tolerance: 0.5) {
            record.lastCommand = command.id; record.lastFrame = before; record.cycle = cycle
            if let key { history[key] = record }
            return (command.name, false)
        }
        var resizable = DarwinBoolean(false)
        let canResize = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success && resizable.boolValue
        if !canResize {
            desired.origin = WMGeometry.alignAcceptedSize(before.size, desired: desired, anchor: p.anchor, screen: destination.visible)
            desired.size = before.size
        }
        let setResult = apply(window, desired: desired, anchor: p.anchor, screen: destination.visible, resize: canResize && before.size != desired.size, crossingDisplay: source.id != destination.id)
        guard let after = Self.rect(window) else { return ("The app stopped responding while moving its window.", true) }
        let changed = !WMGeometry.near(before, after, tolerance: 0.5)
        if changed {
            switch command.operation {
            case .undo:
                record.undo.removeLast(); record.redo.append(before)
            case .redo:
                record.redo.removeLast(); record.undo.append(before)
            default:
                record.undo.append(before); record.redo = []
            }
            record.undo = Array(record.undo.suffix(30)); record.redo = Array(record.redo.suffix(30))
        }
        record.lastFrame = after; record.lastCommand = command.id; record.cycle = cycle; record.touched = Date()
        if let key { history[key] = record }
        if history.count > 128, let oldest = history.min(by: { $0.value.touched < $1.value.touched })?.key { history.removeValue(forKey: oldest) }
        if !changed && !WMGeometry.near(after, desired) { return ("The app did not accept the requested window bounds (AX \(setResult.rawValue)).", true) }
        if !WMGeometry.near(after, desired, tolerance: 3) {
            return ("\(command.name) — adjusted to the app's supported size", false)
        }
        return (command.name, false)
    }
    // Size → position → size handles clamping at the old position, even on one display.
    // This sequence is also used by Rectangle;
    // see THIRD_PARTY_NOTICES.md. Only retry when the readback differs.
    private func apply(_ window: AXUIElement, desired: CGRect, anchor: WMAnchor, screen: CGRect, resize: Bool, crossingDisplay: Bool) -> AXError {
        func size() -> AXError {
            guard resize else { return .success }
            var s = desired.size
            guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
            return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
        func position(_ point: CGPoint) -> AXError {
            var p = point
            guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
        var result = size()
        let moved = position(desired.origin)
        if moved != .success { result = moved }
        if resize { let sized = size(); if sized != .success { result = sized } }
        if let accepted = Self.rect(window), !WMGeometry.near(accepted, desired) {
            let aligned = WMGeometry.alignAcceptedSize(accepted.size, desired: desired, anchor: anchor, screen: screen)
            if hypot(accepted.minX-aligned.x, accepted.minY-aligned.y) > 1 { _ = position(aligned) }
        }
        return result
    }

    func capture(apps: [(pid_t, String, String)], screens: [WMScreen], visibleIDs: Set<CGWindowID>? = nil, completion: @escaping ([WMSceneWindow]) -> Void) {
        queue.async {
            var captured: [WMSceneWindow] = []
            for (pid, bundle, name) in apps {
                let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.15)
                guard let windows = Self.value(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for (index, window) in windows.enumerated() {
                    AXUIElementSetMessagingTimeout(window, 0.15)
                    guard Self.value(window, kAXRoleAttribute) as? String == kAXWindowRole,
                          Self.value(window, kAXMinimizedAttribute) as? Bool != true,
                          Self.value(window, "AXFullScreen") as? Bool != true,
                          let capturedFrame = Self.rect(window), let screen = WMGeometry.screen(for: capturedFrame, screens: screens), captured.count < 64 else { continue }
                    if let visibleIDs {
                        var id: CGWindowID = 0
                        guard self.bridge?(window, &id) == .success, visibleIDs.contains(id) else { continue }
                    }
                    let r = WMGeometry.clamp(capturedFrame, inside: screen.visible)
                    let p = WMPlacement(width: .percent(r.width/screen.visible.width*100), height: .percent(r.height/screen.visible.height*100), anchor: .topLeft,
                                        offsetX: .percent((r.minX-screen.visible.minX)/screen.visible.width*100), offsetY: .percent((r.minY-screen.visible.minY)/screen.visible.height*100), displayID: screen.id, useGaps: false)
                    captured.append(.init(bundleID: bundle, appName: name, title: Self.value(window, kAXTitleAttribute) as? String ?? "", ordinal: index, placement: p))
                }
            }
            DispatchQueue.main.async { completion(captured) }
        }
    }
    func restore(scene: WMScene, screens: [WMScreen], cursor: CGPoint, config: WMConfiguration, apps: [String: pid_t], completion: @escaping (WMOutcome) -> Void) {
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            var count = 0, skipped = 0
            var used = Set<String>()
            for item in scene.windows {
                guard let pid = apps[item.bundleID] else { skipped += 1; continue }
                let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.2)
                guard let windows = Self.value(app, kAXWindowsAttribute) as? [AXUIElement] else { skipped += 1; continue }
                let candidates = windows.enumerated().filter { index, w in
                    Self.value(w, kAXRoleAttribute) as? String == kAXWindowRole && !used.contains("\(pid):\(index)")
                }
                let match = candidates.first { !item.title.isEmpty && Self.value($0.element,kAXTitleAttribute) as? String == item.title }
                    ?? candidates.first { $0.offset == item.ordinal }
                guard let match else { skipped += 1; continue }
                var id: CGWindowID = 0
                guard self.bridge?(match.element, &id) == .success else { skipped += 1; continue }
                used.insert("\(pid):\(match.offset)")
                let command = WMCommand(id: "scene-\(item.id)", name: scene.name, placement: item.placement)
                if self.perform(command, target: .init(pid: pid, windowID: id), screens: screens, cursor: cursor, config: config).1 { skipped += 1 } else { count += 1 }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            DispatchQueue.main.async { completion(.init(message: "Restored \(count) window\(count == 1 ? "" : "s")\(skipped > 0 ? "; \(skipped) unavailable" : "")", milliseconds: ms, failed: count == 0)) }
        }
    }
}

final class WindowManager: NSObject, ObservableObject {
    static let shared = WindowManager()
    @Published private(set) var configuration: WMConfiguration
    @Published private(set) var issues: [String] = []
    @Published private(set) var lastOutcome: WMOutcome?
    @Published var capturing = false
    var configurationDidChange: (() -> Void)?
    private let executor = WMExecutor()
    private var registrations: [WMShortcut: EventHotKeyRef] = [:]
    private var actionsByHotkey: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    private var statusItem: NSStatusItem?
    private(set) var lastExternalPID: pid_t?
    private var observer: NSObjectProtocol?
    private var loadIssue: String?
    private var feedbackPanel: NSPanel?
    private var feedbackGeneration = 0
    static let signature: OSType = 0x574D4752 // WMGR
    static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("switcharoo/window-management.json")
    }
    override init() {
        let url = Self.settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            do { configuration = try JSONDecoder().decode(WMConfiguration.self, from: Data(contentsOf: url)).validated() }
            catch { var defaults = WMConfiguration(); defaults.enabled = false; configuration = defaults; loadIssue = "Could not load saved settings: \(error.localizedDescription). The file has been preserved." }
        } else { configuration = WMConfiguration() }
        super.init()
    }
    func start() {
        lastExternalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalPID = app.processIdentifier
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == WindowManager.signature else { return OSStatus(eventNotHandledErr) }
            WindowManager.shared.handleHotkey(id.id)
            return noErr
        }, 1, &spec, nil, &handler)
        rebind()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Switcharoo window manager")
        rebuildMenu()
    }
    static func screens() -> [WMScreen] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            WMScreen(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                     name: screen.localizedName, frame: WMGeometry.fromAppKit(screen.frame, primaryTop: top), visible: WMGeometry.fromAppKit(screen.visibleFrame, primaryTop: top))
        }
    }
    static func cursor() -> CGPoint {
        .init(x: NSEvent.mouseLocation.x, y: (NSScreen.screens.first?.frame.maxY ?? 0)-NSEvent.mouseLocation.y)
    }
    func target() -> WMTarget? {
        if LauncherController.shared.isVisible { return LauncherController.shared.actionTarget }
        if let app = NSApp.delegate as? App, app.panel?.isVisible == true,
           app.selected >= 0, app.selected < app.rows.count, app.rows[app.selected].commandID == nil {
            let r = app.rows[app.selected]
            return .init(pid: r.pid, windowID: r.windowID == 0 ? nil : r.windowID)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == ProcessInfo.processInfo.processIdentifier,let own = ToolWindowHost.shared.nativeWindow(nil) {
            return .init(pid: ProcessInfo.processInfo.processIdentifier,windowID: CGWindowID(own.windowNumber))
        }
        guard let pid = front == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : front,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return .init(pid: pid, windowID: nil)
    }
    func executeAction(_ id: String) {
        if id.hasPrefix("tool:"), let tool = SwitcharooTool(rawValue: String(id.dropFirst(5))) { LauncherController.shared.show(tool == .schedule ? .schedule : .timers); return }
        if id.hasPrefix("scene:"), let scene = configuration.scenes.first(where: { "scene:\($0.id.uuidString)" == id }) { restore(scene) }
        else { execute(id: id) }
    }
    func execute(id: String) {
        guard let command = configuration.commands.first(where: { $0.id == id && $0.enabled }) else { return }
        execute(command: command)
    }
    func execute(command: WMCommand) {
        var validation = WMConfiguration(); validation.commands = [command]
        do { _ = try validation.validated() }
        catch { showFeedback(error.localizedDescription); return }
        guard let target = target() else { showOutcome(.init(message: "Select an app window first.", milliseconds: 0, failed: true)); return }
        executor.enqueue(command: command, target: target, screens: Self.screens(), cursor: Self.cursor(), config: configuration) { [weak self] result in
            self?.showOutcome(result)
        }
    }
    func showOutcome(_ result: WMOutcome) {
        lastOutcome = result
        if result.failed { showFeedback(result.message) }
        // Log only the action and timing. No window titles or document contents.
        switcharooLog("wm: \(result.message) latency=\(String(format: "%.1f",result.milliseconds))ms failed=\(result.failed)")
    }
    private func showFeedback(_ message: String) {
        if feedbackPanel == nil {
            let panel = NSPanel(contentRect: .init(x: 0,y: 0,width: 440,height: 70), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.ignoresMouseEvents = true
            feedbackPanel = panel
        }
        guard let panel = feedbackPanel, let screen = NSScreen.main else { return }
        let background = NSVisualEffectView(frame: .init(x: 0,y: 0,width: 440,height: 70))
        background.material = .popover; background.state = .active; background.wantsLayer = true; background.layer?.cornerRadius = 14
        let label = NSTextField(wrappingLabelWithString: message); label.font = SwitcharooTypography.font(size: 13)
        label.frame = .init(x: 18,y: 16,width: 404,height: 40); background.addSubview(label)
        panel.contentView = background
        panel.setFrameOrigin(.init(x: screen.visibleFrame.midX-220,y: screen.visibleFrame.minY+80))
        panel.orderFrontRegardless()
        feedbackGeneration += 1; let generation = feedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now()+3) { [weak self] in
            if self?.feedbackGeneration == generation { self?.feedbackPanel?.orderOut(nil) }
        }
    }
    func save(_ draft: WMConfiguration) throws {
        let validated = try draft.validated()
        let reserved = AppShortcuts.shared.configuration.reserved
        let bindings = validated.commands.filter(\.enabled).compactMap(\.shortcut)+validated.scenes.compactMap(\.shortcut)
        guard !bindings.contains(where:reserved.contains) else { throw WMValidationError(message:"That shortcut is assigned to Switcharoo's launcher or switcher.") }
        let data = try Self.encode(validated)
        let url = Self.settingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Keep the last readable configuration available for rollback.
            let prior = try Data(contentsOf: url)
            try prior.write(to: url.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        configuration = validated; loadIssue = nil
        rebind(); rebuildMenu(); configurationDidChange?()
    }
    static func encode(_ config: WMConfiguration) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(config)
    }
    func importSettings(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 2_000_000 else { throw WMValidationError(message: "Settings file is too large.") }
        try save(JSONDecoder().decode(WMConfiguration.self, from: Data(contentsOf: url)))
    }
    func suspendForRecording() {
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations = [:]; actionsByHotkey = [:]
    }
    func rebind() {
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations = [:]; actionsByHotkey = [:]; issues = loadIssue.map { [$0] } ?? []
        guard configuration.enabled else { return }
        var bindings = configuration.commands.filter(\.enabled).compactMap { c in c.shortcut.map { (c.id,c.name,$0) } }
        bindings += configuration.scenes.compactMap { c in c.shortcut.map { ("scene:\(c.id.uuidString)",c.name,$0) } }
        for (index, entry) in bindings.enumerated() {
            let id = UInt32(index+100)
            var ref: EventHotKeyRef?
            let error = RegisterEventHotKey(entry.2.keyCode,entry.2.modifiers,EventHotKeyID(signature: Self.signature,id: id),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&ref)
            if error == noErr, let ref { registrations[entry.2] = ref; actionsByHotkey[id] = entry.0 }
            else { issues.append("\(entry.1): shortcut in use (\(error))") }
        }
        switcharooLog("wm: registered=\(registrations.count) conflicts=\(issues.count)")
    }
    private func handleHotkey(_ id: UInt32) {
        guard let action = actionsByHotkey[id] else { return }
        if action.hasPrefix("scene:"), let uuid = UUID(uuidString: String(action.dropFirst(6))), let scene = configuration.scenes.first(where: { $0.id == uuid }) { restore(scene) }
        else { execute(id: action) }
    }
    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Switcharoo", action: nil,keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        let launcher = NSMenuItem(title: "Open Switcharoo",action: #selector(openLauncher),keyEquivalent: ""); launcher.target = self; menu.addItem(launcher)
        let prefs = NSMenuItem(title: "Window Management…",action: #selector(openPreferences),keyEquivalent: ","); prefs.target = self; menu.addItem(prefs)
        let show = NSMenuItem(title: "Switch Windows",action: #selector(showSwitcher),keyEquivalent: ""); show.target = self; menu.addItem(show)
        for tool in SwitcharooTool.allCases {
            let item = NSMenuItem(title: tool.title,action: #selector(menuTool(_:)),keyEquivalent: "")
            item.target = self; item.representedObject = tool.id; menu.addItem(item)
        }
        menu.addItem(.separator())
        for command in configuration.commands.filter(\.enabled) {
            let item = NSMenuItem(title: command.name,action: #selector(menuCommand(_:)),keyEquivalent: "")
            item.target = self; item.representedObject = command.id
            menu.addItem(item)
        }
        if !configuration.scenes.isEmpty {
            menu.addItem(.separator())
            for scene in configuration.scenes {
                let item = NSMenuItem(title: scene.name, action: #selector(menuScene(_:)),keyEquivalent: "")
                item.target = self; item.representedObject = scene.id.uuidString; menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let retry = NSMenuItem(title: "Retry Shortcuts",action: #selector(retryShortcuts),keyEquivalent: ""); retry.target = self; menu.addItem(retry)
        let pause = NSMenuItem(title: configuration.enabled ? "Pause Window Shortcuts" : "Enable Window Shortcuts", action: #selector(toggleShortcuts),keyEquivalent: ""); pause.target = self; menu.addItem(pause)
        let quit = NSMenuItem(title: "Quit Switcharoo",action: #selector(quitManager),keyEquivalent: ""); quit.target = self; menu.addItem(quit)
        statusItem?.menu = menu
    }
    @objc private func menuTool(_ item: NSMenuItem) { if let id = item.representedObject as? String,let tool = SwitcharooTool(rawValue: id) { LauncherController.shared.show(tool == .schedule ? .schedule : .timers) } }
    @objc func openLauncher() { LauncherController.shared.show() }
    @objc func openPreferences() { LauncherController.shared.show(.windowControls) }
    @objc func showSwitcher() { (NSApp.delegate as? App)?.show(startReversed: false,quick: false) }
    @objc private func menuCommand(_ item: NSMenuItem) { if let id = item.representedObject as? String { execute(id: id) } }
    @objc private func menuScene(_ item: NSMenuItem) {
        if let id = item.representedObject as? String, let scene = configuration.scenes.first(where: { $0.id.uuidString == id }) { restore(scene) }
    }
    @objc func retryShortcuts() { rebind(); rebuildMenu() }
    @objc private func toggleShortcuts() { var draft = configuration; draft.enabled.toggle(); do { try save(draft) } catch { showFeedback(error.localizedDescription) } }
    @objc private func quitManager() { NSApp.terminate(nil) }
    func captureLayout(completion: @escaping (WMScene?) -> Void) {
        guard AXIsProcessTrusted() else { showFeedback("Allow Accessibility access before capturing a layout."); completion(nil); return }
        capturing = true
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app -> (pid_t,String,String)? in guard let bundle = app.bundleIdentifier else { return nil }; return (app.processIdentifier,bundle,app.localizedName ?? bundle) }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let visibleIDs = Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        executor.capture(apps: apps,screens: Self.screens(),visibleIDs: visibleIDs) { [weak self] windows in
            self?.capturing = false
            completion(windows.isEmpty ? nil : .init(name: "Workspace \(Date.now.formatted(date: .omitted,time: .shortened))",windows: windows))
        }
    }
    func restore(_ scene: WMScene) {
        var validation = WMConfiguration(); validation.commands = []; validation.scenes = [scene]
        do { _ = try validation.validated() }
        catch { showFeedback(error.localizedDescription); return }
        var apps: [String:pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications { if let id = app.bundleIdentifier { apps[id] = app.processIdentifier } }
        executor.restore(scene: scene,screens: Self.screens(),cursor: Self.cursor(),config: configuration,apps: apps) { [weak self] result in self?.showOutcome(result) }
    }
    func handleURL(_ url: URL) {
        let items = URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems ?? []
        var args: [String:String] = [:]
        for item in items { if args[item.name] == nil { args[item.name] = item.value } }
        if url.host == "window", let id = args["id"] ?? url.path.split(separator: "/").first.map(String.init) { execute(id: id) }
        if url.host == "layout", let id = args["id"], let scene = configuration.scenes.first(where: { $0.id.uuidString == id || $0.name == id }) { restore(scene) }
        if url.host == "launcher" { LauncherController.shared.show() }
        if let host = url.host, let tool = SwitcharooTool(rawValue: host) {
            if args["fullscreen"] == "true" || args["window"] == "true" { ToolWindowHost.shared.show(tool,fullscreen: args["fullscreen"] == "true") }
            else { LauncherController.shared.show(tool == .schedule ? .schedule : .timers) }
        }
        if url.host == "preferences" { openPreferences() }
        if url.host == "resize" {
            func measure(_ s: String?) -> WMMeasure? {
                guard let s else { return nil }
                if s.hasSuffix("%"), let n = Double(s.dropLast()) { return .percent(n) }
                return Double(s).map(WMMeasure.points)
            }
            var p = WMPlacement(width: measure(args["width"]),height: measure(args["height"]),anchor: WMAnchor(rawValue: args["anchor"] ?? "center") ?? .center,useGaps: false)
            if let x = measure(args["x"]) { p.offsetX = x }; if let y = measure(args["y"]) { p.offsetY = y }
            let c = WMCommand(id: "temporary",name: "Custom placement",placement: p)
            var validation = WMConfiguration(); validation.commands = [c]
            do {
                _ = try validation.validated()
                // A malformed explicit dimension must not silently become "keep size".
                guard args["width"] == nil || p.width != nil, args["height"] == nil || p.height != nil,
                      args["x"] == nil || measure(args["x"]) != nil, args["y"] == nil || measure(args["y"]) != nil else { throw WMValidationError(message: "Invalid size or offset in window link.") }
                execute(command: c)
            } catch { showFeedback(error.localizedDescription) }
        }
    }
}
