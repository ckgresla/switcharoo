import AppKit
import SwiftUI

/// Renders both existing switcher modes from the same sample rows and production view.
enum LauncherDiagnostics {
    /// Documentation captures use production views offscreen, with sample data and
    /// isolated launcher preferences. No hotkeys, calendar access, or focus changes.
    static func renderReadme() {
        renderSwitcherModes()
        ApplicationCatalog.shared.refresh()
        CalculatorEngine.shared.prewarm()
        let model = LauncherModel()
        model.usage = LauncherUsage()
        model.showingCommands = false
        let calculator = CalculatorModel()
        var windows: [NSPanel] = []
        func capture(_ name: String, height: CGFloat, dark: Bool = false) {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 700, height: height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: LauncherView(model: model, catalog: .shared,
                manager: .shared, calculator: calculator, preview: true))
            panel.contentView = view
            windows.append(panel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "/tmp/switcharoo-readme-" + name + ".png"))
            }
        }
        capture("compact", height: 90)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            model.query = "Finder"
            model.selectedID = "app:/System/Library/CoreServices/Finder.app"
            capture("launcher", height: 198)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            model.query = "(1GB per second) in Mb"
            calculator.update(model.query)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            capture("calculator", height: 238)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            model.navigate(.schedule)
            capture("schedule", height: 620)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            model.navigate(.timers)
            capture("timers", height: 620, dark: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            _ = windows.count
            NSApp.terminate(nil)
        }
    }

    static func renderSwitcherModes() {
        let view = SwitcherView(frame:CGRect(x:0,y:0,width:SwitcharooSearchMetrics.panelWidth,height:200))
        let samples = [("ChatGPT","A conversation","com.openai.codex"),("Dia","A browser tab","company.thebrowser.dia"),("Emacs","notes.org","org.gnu.Emacs")]
        view.rows = samples.enumerated().map { index,sample in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier:sample.2).map { NSWorkspace.shared.icon(forFile:$0.path) }
            return WindowRecord(windowID:UInt32(index+1),pid:0,appName:sample.0,title:sample.1,icon:icon)
        }
        view.selected = 0
        let window = NSPanel(contentRect:view.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = view
        for quick in [false,true] {
            view.quickMode = quick
            view.setFrameSize(CGSize(width:SwitcharooSearchMetrics.panelWidth,height:(quick ? 0:50)+28+36*3))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { continue }
            view.cacheDisplay(in:view.bounds,to:rep)
            let mode = quick ? "command-tab" : "option-tab"
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/switcharoo-style-"+mode+".png"))
        }
    }
}
