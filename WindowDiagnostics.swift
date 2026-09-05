import AppKit

// Explicit diagnostics target a separate, disposable fixture process. AX calls
// to a window in the same process bypass IPC and invoke AppKit on the caller's
// thread; that is not a valid test of the real window-management path.
final class WindowDiagnostics {
    static let shared = WindowDiagnostics()
    private let executor = WMExecutor()
    private var results: [[String: Any]] = []
    private var index = 0
    private var frames: [CGRect] = []
    private var pid: pid_t?
    private let actions = ["left-half","right-half","maximize","center","chat-window","reasonable-size","top-left","bottom-right","grow","undo","redo"]
    private func fixtureState() -> (pid_t,CGRect)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/switcharoo-fixture-state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String:Double],
              let process = state["pid"],let x = state["x"],let y = state["y"],let w = state["width"],let h = state["height"],let updated = state["updated"],Date().timeIntervalSince1970-updated < 3 else { return nil }
        return (pid_t(process),.init(x: x,y: y,width: w,height: h))
    }
    func run() {
        guard AXIsProcessTrusted() else { finish(error: "Accessibility permission unavailable for the signed diagnostic app."); return }
        guard let state = fixtureState(),NSRunningApplication(processIdentifier: state.0)?.bundleIdentifier == "systems.wafer.switcharoo.fixture" else { finish(error: "Launch the disposable WindowFixture app first."); return }
        pid = state.0; next()
    }
    private func next() {
        guard index < actions.count else { testLayout(); return }
        guard let (pid,before) = fixtureState() else { finish(error: "Fixture stopped responding"); return }
        let id = actions[index], config = WMConfiguration(), screens = WindowManager.screens()
        guard let screen = WMGeometry.screen(for: before,screens: screens),let command = config.commands.first(where: { $0.id == id }) else { finish(error: "No display or command"); return }
        var expected = WMGeometry.frame(command,current: before,source: screen.visible,target: screen.visible,config: config)
        if (id == "undo" || id == "redo"), frames.count >= 2 { expected = frames[frames.count-2] }
        executor.enqueue(command: command,target: .init(pid: pid,windowID: nil),screens: screens,cursor: WindowManager.cursor(),config: config) { result in
            DispatchQueue.main.asyncAfter(deadline: .now()+0.09) {
                guard let (_,actual) = self.fixtureState() else { self.finish(error: "Fixture disappeared"); return }
                self.results.append(["action":id,"passed":!result.failed && WMGeometry.near(actual,expected,tolerance: 3),"milliseconds":result.milliseconds,"message":result.message,"expected":NSStringFromRect(expected),"actual":NSStringFromRect(actual)])
                self.frames.append(actual); self.index += 1; self.next()
            }
        }
    }
    private func testLayout() {
        guard let (pid,before) = fixtureState() else { finish(error: "Fixture disappeared"); return }
        let screens = WindowManager.screens(),config = WMConfiguration()
        executor.capture(apps: [(pid,"systems.wafer.switcharoo.fixture","WindowFixture")],screens: screens) { captured in
            self.results.append(["action":"capture-layout","passed":captured.count == 1,"milliseconds":0])
            guard captured.count == 1 else { self.finish(error: "Expected one fixture window"); return }
            let scene = WMScene(name: "Fixture layout",windows: captured)
            var configToValidate = config; configToValidate.scenes = [scene]
            do { _ = try configToValidate.validated() } catch { self.finish(error: error.localizedDescription); return }
            self.executor.enqueue(command: config.commands.first { $0.id == "left-half" }!,target: .init(pid: pid,windowID: nil),screens: screens,cursor: WindowManager.cursor(),config: config) { result in
                self.results.append(["action":"move-before-restore","passed":!result.failed,"milliseconds":result.milliseconds])
                self.executor.restore(scene: scene,screens: screens,cursor: WindowManager.cursor(),config: config,apps: ["systems.wafer.switcharoo.fixture":pid]) { result in
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.12) {
                        let actual = self.fixtureState()?.1 ?? .zero
                        self.results.append(["action":"restore-layout","passed":!result.failed && WMGeometry.near(actual,before,tolerance: 3),"milliseconds":result.milliseconds,"actual":NSStringFromRect(actual),"expected":NSStringFromRect(before)])
                        self.testNativeWindow()
                    }
                }
            }
        }
    }
    private func testNativeWindow() {
        ToolWindowHost.shared.show(.schedule,preview: true)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.15) {
            guard let window = ToolWindowHost.shared.nativeWindow(nil) else { self.finish(error: "Tool window did not become key"); return }
            let before = window.frame, config = WMConfiguration(), target = WMTarget(pid: ProcessInfo.processInfo.processIdentifier,windowID: CGWindowID(window.windowNumber))
            let screens = WindowManager.screens(),cursor = WindowManager.cursor()
            let move = NativeWindowMoves.shared.perform(config.commands.first { $0.id == "right-half" }!,target: target,screens: screens,cursor: cursor,config: config)
            let moved = window.frame
            self.results.append(["action":"native-tool-placement","passed":!move.failed && moved != before,"milliseconds":move.milliseconds])
            let undo = NativeWindowMoves.shared.perform(config.commands.first { $0.id == "undo" }!,target: target,screens: screens,cursor: cursor,config: config)
            self.results.append(["action":"native-tool-undo","passed":!undo.failed && WMGeometry.near(window.frame,before,tolerance: 3),"milliseconds":undo.milliseconds])
            let redo = NativeWindowMoves.shared.perform(config.commands.first { $0.id == "redo" }!,target: target,screens: screens,cursor: cursor,config: config)
            self.results.append(["action":"native-tool-redo","passed":!redo.failed && WMGeometry.near(window.frame,moved,tolerance: 3),"milliseconds":redo.milliseconds])
            self.results.append(["action":"native-tool-in-switcher","passed":listWindows().contains { $0.windowID == CGWindowID(window.windowNumber) && $0.pid == target.pid },"milliseconds":0])
            self.finish()
        }
    }
    private func finish(error: String? = nil) {
        var report: [String:Any] = ["tests":results,"font":SwitcharooTypography.font(size: 14).fontName,"passed":error == nil && results.count == actions.count+7 && results.allSatisfy { $0["passed"] as? Bool == true }]
        if let error { report["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: "/tmp/switcharoo-window-smoke-test.json"),options: .atomic) }
        if let pid,let app = NSRunningApplication(processIdentifier: pid),app.bundleIdentifier == "systems.wafer.switcharoo.fixture" { app.terminate() }
        NSApp.terminate(nil)
    }
}
