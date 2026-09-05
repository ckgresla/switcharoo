import AppKit
import SwiftUI

// Each tool owns its view and state; the host owns native window behavior.
// Additional tools register here without changing the window switcher or AX engine.
enum SwitcharooTool: String, CaseIterable, Identifiable {
    case schedule, timer
    var id: String { rawValue }
    var title: String { self == .schedule ? "My Schedule" : "Timers" }
    var symbol: String { self == .schedule ? "calendar" : "timer" }
    var keywords: String { self == .schedule ? "calendar agenda meetings my schedule" : "timer countdown focus" }
}

enum ToolStyle {
    static func background(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.125 : 1) }
    static func secondary(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.65 : 0.43) }
    static func raised(_ scheme: ColorScheme) -> Color { Color(white: scheme == .dark ? 0.17 : 0.965) }
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : .black
    }
}
struct ToolButton: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(SwitcharooTypography.ui(size: 13,weight: .medium))
            .padding(.horizontal,14).padding(.vertical,9)
            .foregroundStyle(prominent ? (scheme == .dark ? Color.black : .white) : .primary)
            .background(prominent ? (scheme == .dark ? Color.white : Color(white: 0.15)) : ToolStyle.raised(scheme),in: RoundedRectangle(cornerRadius:6))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

final class ToolWindowHost: NSObject, NSWindowDelegate {
    static let shared = ToolWindowHost()
    private var windows: [SwitcharooTool:NSWindow] = [:]
    func show(_ tool: SwitcharooTool, fullscreen: Bool = false, preview: Bool = false) {
        let window: NSWindow
        if let existing = windows[tool] { window = existing }
        else {
            window = NSWindow(contentRect: .init(x: 0,y: 0,width: 940,height: 740),styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing: .buffered,defer: false)
            window.title = tool.title; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
            window.minSize = .init(width: 640,height: 500); window.collectionBehavior = [.fullScreenPrimary]
            if !preview { window.setFrameAutosaveName("Switcharoo.tool.\(tool.id)") }
            window.delegate = self; window.toolbarStyle = .unified
            switch tool {
            case .schedule: window.contentView = NSHostingView(rootView: ScheduleView(model: preview ? ScheduleModel.preview() : .shared))
            case .timer: window.contentView = NSHostingView(rootView: CountdownView(model: preview ? CountdownModel.sample() : .shared))
            }
            if window.frame.origin == .zero { window.center() }
            windows[tool] = window
        }
        window.deminiaturize(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if fullscreen && !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func nativeWindow(_ id: CGWindowID?) -> NSWindow? {
        if let id { return windows.values.first { $0.windowNumber == Int(id) && ($0.isVisible || $0.isMiniaturized) } }
        return windows.values.first { $0.isKeyWindow || $0.isMainWindow }
    }
    func snapshot(_ tool: SwitcharooTool, to url: URL, dark: Bool) {
        show(tool,preview: true)
        windows[tool]?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in
            guard let view = self?.windows[tool]?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds,to: rep)
            try? rep.representation(using: .png,properties: [:])?.write(to: url)
        }
    }
}


/// nil appearance deliberately preserves AppKit's live system inheritance.
enum SwitcharooAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    static var saved: Self { Self(rawValue:UserDefaults.standard.string(forKey:"appearance.mode") ?? "system") ?? .system }
    func apply() { NSApp.appearance = self == .system ? nil : NSAppearance(named:self == .dark ? .darkAqua : .aqua) }
    func save() { UserDefaults.standard.set(rawValue,forKey:"appearance.mode"); apply() }
}
enum SystemAppearance {
    private static var running = false
    // This only changes the current system dark-mode value. It does not write
    // Switcharoo's preference or macOS's automatic/scheduled appearance setting.
    static let toggleScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
    static func toggle(completion: @escaping (String?) -> Void) {
        guard !running else { return }; running = true
        DispatchQueue.global(qos:.userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
            process.arguments = ["-e",toggleScript]
            let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            var failure: String?
            do {
                try process.run()
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 { failure = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "Could not change system appearance." }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { running = false; completion(failure) }
        }
    }
}
