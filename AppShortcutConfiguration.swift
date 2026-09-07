import Foundation

enum AppShortcutID: String, CaseIterable {
    case launcher, search, quick, settings
    var title: String { switch self { case .launcher: return "Launcher"; case .search: return "Window Search"; case .quick: return "Quick Switcher"; case .settings: return "Settings" } }
    var defaultShortcut: WMShortcut {
        switch self {
        case .launcher: return .init(keyCode:49,modifiers:2304)
        case .search: return .init(keyCode:48,modifiers:2048)
        case .quick: return .init(keyCode:48,modifiers:256)
        case .settings: return .init(keyCode:43,modifiers:256)
        }
    }
}
struct AppShortcutConfiguration: Codable, Equatable {
    private var bindings: [String:WMShortcut] = [:]
    subscript(_ id: AppShortcutID) -> WMShortcut {
        get { bindings[id.rawValue] ?? id.defaultShortcut }
        set { bindings[id.rawValue] = newValue }
    }
    static func reversed(_ shortcut: WMShortcut) -> WMShortcut { .init(keyCode:shortcut.keyCode,modifiers:shortcut.modifiers | 512) }
    var reserved: Set<WMShortcut> {
        Set(AppShortcutID.allCases.map { self[$0] } + [Self.reversed(self[.search]),Self.reversed(self[.quick])])
    }
    // Commit quick switching when its primary held modifier is released.
    var quickHoldModifier: UInt32 {
        let mods = self[.quick].modifiers
        return mods & 256 != 0 ? 256 : mods & 2048 != 0 ? 2048 : 4096
    }
    func quickDirection(keyCode: UInt32,modifiers: UInt32) -> Bool? {
        guard keyCode == self[.quick].keyCode else { return nil }
        if modifiers == self[.quick].modifiers { return false }
        if modifiers == Self.reversed(self[.quick]).modifiers { return true }
        return nil
    }
    func validated(windowShortcuts: Set<WMShortcut> = []) throws -> Self {
        var seen = Set<WMShortcut>()
        for id in AppShortcutID.allCases {
            let key = self[id]
            guard key.keyCode <= 127,key.modifiers & ~UInt32(6912) == 0,key.modifiers & 6400 != 0 else { throw WMValidationError(message:"Include ⌘, ⌥, or ⌃.") }
            guard ![UInt32(53),55,56,57,58,59,60,61,62,63].contains(key.keyCode) else { throw WMValidationError(message:"Choose a key other than Escape or a modifier.") }
            if id == .search || id == .quick {
                guard key.modifiers & 512 == 0 else { throw WMValidationError(message:"Shift is reserved for switching in reverse.") }
            }
            let keys = id == .search || id == .quick ? [key,Self.reversed(key)] : [key]
            for candidate in keys {
                guard seen.insert(candidate).inserted else { throw WMValidationError(message:"That shortcut is already used by Switcharoo.") }
                guard !windowShortcuts.contains(candidate) else { throw WMValidationError(message:"That shortcut is assigned to a window command.") }
            }
            // Preserve text editing and in-panel actions, including the action menu.
            let panelReserved: Set<WMShortcut> = Set([0,6,7,8,9,12,13,40,46,4,1].map { WMShortcut(keyCode:UInt32($0),modifiers:256) })
            guard !panelReserved.contains(key) else { throw WMValidationError(message:"That shortcut is reserved for editing or window actions.") }
        }
        return self
    }
}
