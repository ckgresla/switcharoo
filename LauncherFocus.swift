import AppKit
import ApplicationServices

/// Capture before activating our panel, and restore before ordering it out.
final class LauncherFocus {
    private var application: NSRunningApplication?
    private var window: AXUIElement?
    var applicationPID: pid_t? { application?.processIdentifier }
    func inherit(from source: LauncherFocus) {
        application = source.application
        window = source.window
    }
    func capture(fallbackPID: pid_t?) {
        let front = NSWorkspace.shared.frontmostApplication
        application = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : fallbackPID.flatMap(NSRunningApplication.init(processIdentifier:))
        window = nil
        guard let application,application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app,0.025)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value) == .success,
           let value,CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = (value as! AXUIElement)
        }
    }
    func restore() {
        guard let application,!application.isTerminated else { return }
        if let window {
            AXUIElementSetMessagingTimeout(window,0.025)
            AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
            AXUIElementSetAttributeValue(window,kAXFocusedAttribute as CFString,kCFBooleanTrue)
            AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        }
        application.activate(options:[])
    }
}

extension LauncherController {
    /// Real panel handoff with a deliberately unconfirmed, different app selected.
    func runHandoffRegression(app: App) {
        var checks: [String:Bool] = [:]
        app.show(startReversed:false)
        let origin = app.previousFocus.applicationPID
        let candidate = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != origin && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        checks["origin and different candidate available"] = origin != nil && candidate != nil
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            if let candidate {
                let row = WindowRecord(windowID:0,pid:candidate.processIdentifier,appName:candidate.localizedName ?? "Candidate",title:"Unconfirmed",icon:nil)
                app.rows = [row]; app.view.rows = [row]; app.selected = 0; app.view.selected = 0
            }
            self.show(preview:true)
            checks["handoff retains original application"] = self.previousFocus.applicationPID == origin
            checks["launcher action target excludes unconfirmed selection"] = self.actionTarget?.pid == origin
            checks["handoff clears selection and rows"] = app.selected == -1 && app.rows.isEmpty && app.view.rows.isEmpty
            checks["handoff disarms modifier release"] = !app.quickMode && !app.panel.isVisible
            // Exercise the launcher's Escape route, then a late switcher callback.
            self.model.back()
            app.commit()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
            checks["Escape restores original application"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == origin
            checks["Escape closes launcher"] = !self.isVisible
            app.show(startReversed:false)
            if let candidate {
                let row = WindowRecord(windowID:0,pid:candidate.processIdentifier,appName:candidate.localizedName ?? "Candidate",title:"Unconfirmed",icon:nil)
                app.rows = [row]; app.view.rows = [row]; app.selected = 0; app.view.selected = 0
            }
            app.cancel()
            app.commit()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.0) {
            checks["Option-Tab cancel ignores highlighted app"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == origin
            checks["cancel clears pending selection"] = app.selected == -1 && app.rows.isEmpty
            let output: [String:Any] = ["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks]
            if let data = try? JSONSerialization.data(withJSONObject:output,options:.prettyPrinted) {
                try? data.write(to:URL(fileURLWithPath:"/tmp/switcharoo-focus-handoff-regression.json"))
            }
            NSApp.terminate(nil)
        }
    }
}
