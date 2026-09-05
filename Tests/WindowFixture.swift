import AppKit

final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 160,y: 160,width: 640,height: 440),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        window.title = "Switcharoo — temporary window test"; window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Testing window placement. This window closes automatically.")
        label.frame = .init(x: 20,y: 150,width: 540,height: 40); window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.03,repeats: true) { [weak self] _ in self?.record() }
        record()
        // A bounded lifetime also cleans up after a crashed diagnostic runner.
        DispatchQueue.main.asyncAfter(deadline: .now()+45) { NSApp.terminate(nil) }
    }
    func record() {
        let frame = window.frame
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let data: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"x":frame.minX,"y":top-frame.maxY,"width":frame.width,"height":frame.height,"updated":Date().timeIntervalSince1970]
        if let json = try? JSONSerialization.data(withJSONObject: data) { try? json.write(to: URL(fileURLWithPath: "/tmp/switcharoo-fixture-state.json"),options: .atomic) }
    }
}
@main struct Main {
    static func main() {
        let app = NSApplication.shared, delegate = Fixture()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
