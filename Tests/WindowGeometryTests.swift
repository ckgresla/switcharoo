import Foundation
import CoreGraphics

@main
struct WindowGeometryTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func rejects(_ config: WMConfiguration, _ message: String) {
        do { _ = try config.validated(); fatalError("FAIL: accepted \(message)") } catch { checks += 1 }
    }
    static func main() throws {
        let config = WMConfiguration()
        _ = try config.validated()
        check(config.commands.count == 40,"40 defaults")
        let decoded = try JSONDecoder().decode(WMConfiguration.self,from: JSONEncoder().encode(config))
        check(decoded == config,"settings round trip")
        let screen = CGRect(x: 0,y: 25,width: 1440,height: 875)
        let window = CGRect(x: 175,y: 200,width: 700,height: 500)
        func frame(_ id: String, _ cfg: WMConfiguration = config, _ cycle: Int = 0) -> CGRect {
            WMGeometry.frame(cfg.commands.first { $0.id == id }!,current: window,source: screen,target: screen,config: cfg,cycle: cycle)
        }
        check(frame("left-half") == CGRect(x: 0,y: 25,width: 720,height: 875),"left half respects menu bar")
        check(frame("right-half") == CGRect(x: 720,y: 25,width: 720,height: 875),"right half")
        check(frame("maximize") == screen,"maximize excludes reserved screen area")
        check(frame("center").size == window.size,"center never resizes")
        check(frame("maximize-width").minY == window.minY && frame("maximize-width").height == window.height,"maximize width preserves vertical position")
        check(frame("maximize-height").minX == window.minX && frame("maximize-height").width == window.width,"maximize height preserves horizontal position")
        check(frame("move-right").minY == window.minY && frame("move-right").size == window.size,"edge move preserves size and other axis")
        let reasonable = frame("reasonable-size")
        check(reasonable.width == 864 && reasonable.height == 525,"reasonable size reproduces 60 percent rule")
        let large = CGRect(x: 0,y: 30,width: 5000,height: 3000)
        let reasonableLarge = WMGeometry.frame(config.commands.first { $0.id == "reasonable-size" }!,current: window,source: large,target: large,config: config)
        check(reasonableLarge.size == CGSize(width: 1025,height: 900),"reasonable size caps")
        var gaps = config; gaps.outerGap = 10; gaps.innerGap = 12
        let left = frame("left-half",gaps), right = frame("right-half",gaps)
        check(right.minX-left.maxX == 12,"one inner gap shared by two windows")
        check(left.minX == 10 && right.maxX == 1430,"desktop gaps")
        check(left.minY == 35 && left.maxY == 890,"top and bottom gaps")
        check(frame("center",gaps).size == window.size,"gaps cannot shrink center command")
        check(frame("chat-window",gaps).width == 800,"custom point sizing")
        check(frame("chat-window",gaps).height == screen.height,"oversized custom window clamped to laptop")
        let third = frame("center-third")
        check(third.minX == 480 && third.width == 480,"center third")
        check(frame("second-fourth").minX == 360 && frame("third-fourth").minX == 720,"middle fourth offsets")
        check(frame("top-center-sixth").minX == 480 && abs(frame("top-center-sixth").height-438)<1,"sixth")
        var cycling = config; cycling.cycleHalves = true
        check(frame("left-half",cycling,1).width == 960,"half cycles to two thirds")
        check(frame("right-half",cycling,2).minX == 960,"right cycle remains edge aligned")
        check(frame("left-half",cycling,3).width == 720,"half cycle wraps")
        let a = WMScreen(id: 1,name: "Primary",frame: .init(x: 0,y: 0,width: 1440,height: 900),visible: screen)
        let b = WMScreen(id: 2,name: "Left",frame: .init(x: -2560,y: -300,width: 2560,height: 1440),visible: .init(x: -2560,y: -275,width: 2560,height: 1415))
        let c = WMScreen(id: 3,name: "Above",frame: .init(x: 0,y: -1080,width: 1920,height: 1080),visible: .init(x: 0,y: -1055,width: 1920,height: 1055))
        check(WMGeometry.fromAppKit(.init(x: -2560,y: -240,width: 2560,height: 1440),primaryTop: 900) == b.frame,"AX coordinate conversion for left display at different vertical offset")
        check(WMGeometry.fromAppKit(.init(x: 0,y: 900,width: 1920,height: 1080),primaryTop: 900) == c.frame,"AX conversion for display above primary")
        check(WMGeometry.screen(for: .init(x: -900,y: 100,width: 1000,height: 500),screens: [a,b,c])?.id == 2,"largest intersection chooses display")
        check(WMGeometry.screen(for: .init(x: 9000,y: 100,width: 100,height: 100),screens: [a,b,c])?.id == 3,"offscreen window falls back to nearest display")
        var p = WMPlacement(display: .previous)
        check(WMGeometry.destination(p,source: a,screens: [a,b],cursor: .zero).id == 2,"previous display wraps")
        p.display = .cursor
        check(WMGeometry.destination(p,source: a,screens: [a,b],cursor: .init(x: -100,y: 100)).id == 2,"cursor display")
        p.displayID = 999; p.display = .window
        check(WMGeometry.destination(p,source: a,screens: [a,b],cursor: .zero).id == 1,"disconnected pinned display falls back")
        let translated = WMGeometry.moveDisplay(screen,from: screen,to: b.visible)
        check(WMGeometry.near(translated,b.visible),"maximized window stays maximized across displays")
        let target = WMGeometry.placement(.init(anchor: .right),current: window,screen: b.visible,outer: 0,inner: 0)
        check(target.maxX == 0,"negative-coordinate display right edge")
        let minOrigin = WMGeometry.alignAcceptedSize(.init(width: 900,height: 500),desired: .init(x: 720,y: 200,width: 720,height: 500),anchor: .right,screen: screen)
        check(minOrigin.x == 540,"app minimum width preserves right anchor")
        let hugeOrigin = WMGeometry.alignAcceptedSize(.init(width: 2000,height: 2000),desired: screen,anchor: .center,screen: screen)
        check(hugeOrigin == screen.origin,"oversized fixed window keeps title bar on screen")
        for command in config.commands where ![WMOperation.fullscreen,.undo,.redo].contains(command.operation) {
            for s in [a.visible,b.visible,c.visible,CGRect(x: -50,y: 0,width: 120,height: 90)] {
                let r = WMGeometry.frame(command,current: window,source: screen,target: s,config: gaps)
                check(r.width > 0 && r.height > 0 && s.contains(r),"\(command.id) remains valid on \(s)")
            }
        }
        var bad = config; bad.outerGap = -1; rejects(bad,"negative gap")
        bad = config; bad.resizeStep = .infinity; rejects(bad,"infinite step")
        bad = config; bad.commands[0].placement.width = .points(.nan); rejects(bad,"NaN width")
        bad = config; bad.commands[0].placement.width = .percent(101); rejects(bad,"invalid percent")
        bad = config; bad.commands[0].placement.offsetX = .percent(-101); rejects(bad,"invalid offset")
        bad = config; bad.commands[0].shortcut = bad.commands[1].shortcut; rejects(bad,"duplicate enabled shortcut")
        bad.commands[0].enabled = false; _ = try bad.validated(); checks += 1
        bad = config; bad.commands[0].shortcut = .init(keyCode: 48,modifiers: 2048); rejects(bad,"reserved Option Tab")
        bad = config; bad.commands[0].shortcut = .init(keyCode: 4,modifiers: 512); rejects(bad,"shift only shortcut")
        bad = config; bad.commands[0].id = bad.commands[1].id; rejects(bad,"duplicate command id")
        bad = config; bad.scenes = [.init(name: "Empty",windows: [])]; rejects(bad,"empty scene")
        print("PASS: \(checks) geometry, display, configuration, and serialization checks")
    }
}
