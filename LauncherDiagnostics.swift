import AppKit

/// Renders both existing switcher modes from the same sample rows and production view.
enum LauncherDiagnostics {
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
