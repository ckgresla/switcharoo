import AppKit
import Carbon.HIToolbox

final class AppShortcuts: ObservableObject {
    static let shared = AppShortcuts()
    @Published private(set) var configuration: AppShortcutConfiguration
    @Published var message = ""
    private(set) var recording = false
    private var started = false
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var tapRecording = false
    var capturingKeys: Bool { lock.lock(); defer { lock.unlock() }; return tapRecording }
    private var tapConfiguration: AppShortcutConfiguration?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey:"app.shortcuts").flatMap { try? JSONDecoder().decode(AppShortcutConfiguration.self,from:$0) }
        configuration = (try? saved?.validated()) ?? AppShortcutConfiguration()
        tapConfiguration = configuration
    }
    func start() {
        started = true
        message = [LauncherController.shared.hotkeyIssue,(NSApp.delegate as? App)?.searchShortcutIssue].compactMap { $0 }.joined(separator:"\n")
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    func matches(_ id: AppShortcutID,event: NSEvent) -> Bool {
        !recording && configuration[id] == WMShortcut(keyCode:UInt32(event.keyCode),modifiers:Self.modifiers(event.modifierFlags))
    }
    func quickDirection(_ event: CGEvent) -> Bool? {
        lock.lock(); let current = tapConfiguration; lock.unlock()
        var modifiers: UInt32 = 0
        let flags = event.flags
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        return current?.quickDirection(keyCode:UInt32(event.getIntegerValueField(.keyboardEventKeycode)),modifiers:modifiers)
    }
    func quickModifierHeld(_ flags: NSEvent.ModifierFlags) -> Bool { Self.modifiers(flags) & configuration.quickHoldModifier != 0 }
    private func setTap(_ value: AppShortcutConfiguration?) { lock.lock(); tapConfiguration = value; lock.unlock() }
    private func suspend() {
        setTap(nil)
        guard started else { return }
        LauncherController.shared.suspendShortcut()
        (NSApp.delegate as? App)?.suspendSearchShortcuts()
        WindowManager.shared.suspendForRecording()
    }
    private func resume() -> [String] {
        setTap(configuration)
        guard started else { return [] }
        LauncherController.shared.retryShortcut()
        let searchError = (NSApp.delegate as? App)?.registerSearchShortcuts()
        WindowManager.shared.retryShortcuts()
        (NSApp.delegate as? App)?.updateShortcutMenu()
        return [LauncherController.shared.hotkeyIssue,searchError].compactMap { $0 }
    }
    func beginRecording() {
        guard !recording else { return }; recording = true
        lock.lock(); tapRecording = true; lock.unlock(); suspend()
    }
    func endRecording() {
        guard recording else { return }; recording = false
        lock.lock(); tapRecording = false; lock.unlock(); _ = resume()
    }
    func update(_ id: AppShortcutID,to key: WMShortcut?) {
        guard let key else { message = "Use Reset Shortcut to restore the default."; return }
        var candidate = configuration; candidate[id] = key
        do { try apply(candidate); message = "" }
        catch { message = error.localizedDescription }
    }
    private func apply(_ candidate: AppShortcutConfiguration) throws {
        let wm = WindowManager.shared.configuration
        let occupied = Set(wm.commands.filter(\.enabled).compactMap(\.shortcut)+wm.scenes.compactMap(\.shortcut))
        let candidate = try candidate.validated(windowShortcuts:occupied)
        let data = try JSONEncoder().encode(candidate)
        let previous = configuration
        suspend()
        // Carbon cannot reserve native Cmd-Tab, which uses the event tap.
        // Probe other quick-switch shortcuts for claims by another application.
        let quick = candidate[.quick]
        if started,!(quick.keyCode == 48 && quick.modifiers == UInt32(cmdKey)) {
            for binding in [quick,AppShortcutConfiguration.reversed(quick)] {
                var probe: EventHotKeyRef?
                let status = RegisterEventHotKey(binding.keyCode,binding.modifiers,EventHotKeyID(signature:0x50524F42,id:1),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&probe)
                if let probe { UnregisterEventHotKey(probe) }
                if status != noErr { _ = resume(); throw WMValidationError(message:"Quick Switcher: shortcut is in use (\(status)).") }
            }
        }
        configuration = candidate
        let errors = resume()
        guard errors.isEmpty else {
            suspend(); configuration = previous; _ = resume()
            throw WMValidationError(message:errors.joined(separator:"\n"))
        }
        defaults.set(data,forKey:"app.shortcuts")
    }
}
