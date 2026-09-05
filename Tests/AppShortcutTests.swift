import Foundation
@main struct AppShortcutTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool,_ label: String) { precondition(value,label); count += 1 }
        func rejected(_ config: AppShortcutConfiguration,_ label: String) { do { _ = try config.validated(); fatalError(label) } catch { count += 1 } }
        let defaults = AppShortcutConfiguration()
        _ = try defaults.validated()
        check(defaults[.launcher] == .init(keyCode:49,modifiers:2304),"launcher default")
        check(defaults[.search] == .init(keyCode:48,modifiers:2048),"search default")
        check(defaults[.quick] == .init(keyCode:48,modifiers:256),"quick default")
        check(defaults[.settings] == .init(keyCode:43,modifiers:256),"settings default")
        check(defaults.quickDirection(keyCode:48,modifiers:256) == false,"quick forward")
        check(defaults.quickDirection(keyCode:48,modifiers:768) == true,"quick reverse")
        check(defaults.quickDirection(keyCode:48,modifiers:2304) == nil,"extra modifiers do not trigger quick switching")
        check(defaults.quickDirection(keyCode:49,modifiers:256) == nil,"other key not swallowed")
        check(defaults.quickHoldModifier == 256,"Command release default")
        for modifier: UInt32 in [2048,4096,2304] {
            var config = defaults; config[.quick] = .init(keyCode:17,modifiers:modifier)
            _ = try config.validated()
            check(config.quickHoldModifier == (modifier & 256 != 0 ? 256 : modifier),"custom held modifier")
            check(config.quickDirection(keyCode:17,modifiers:modifier) == false,"custom forward")
            check(config.quickDirection(keyCode:17,modifiers:modifier|512) == true,"custom reverse")
            check(config.quickDirection(keyCode:48,modifiers:256) == nil,"old quick binding released")
        }
        for id in AppShortcutID.allCases {
            var config = defaults; config[id] = .init(keyCode:17,modifiers:4352)
            let restored = try JSONDecoder().decode(AppShortcutConfiguration.self,from:JSONEncoder().encode(config))
            check(config == restored,"all bindings persist")
        }
        var duplicate = defaults; duplicate[.launcher] = defaults[.settings]; rejected(duplicate,"duplicate")
        duplicate = defaults; duplicate[.launcher] = AppShortcutConfiguration.reversed(defaults[.quick]); rejected(duplicate,"reverse collision")
        duplicate = defaults; duplicate[.search] = .init(keyCode:17,modifiers:2560); rejected(duplicate,"Shift reverse reserved")
        duplicate = defaults; duplicate[.launcher] = .init(keyCode:17,modifiers:0); rejected(duplicate,"bare key")
        duplicate = defaults; duplicate[.launcher] = .init(keyCode:53,modifiers:256); rejected(duplicate,"Escape cancels")
        duplicate = defaults; duplicate[.launcher] = .init(keyCode:128,modifiers:256); rejected(duplicate,"key range")
        duplicate = defaults; duplicate[.settings] = .init(keyCode:8,modifiers:256); rejected(duplicate,"copy shortcut preserved")
        do { _ = try defaults.validated(windowShortcuts:[defaults[.launcher]]); fatalError("window command conflict") } catch { count += 1 }
        check(defaults.reserved.count == 6,"forward and reverse reserved")
        print("\(count) app shortcut checks passed")
    }
}
