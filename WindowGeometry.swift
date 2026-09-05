import Foundation
import CoreGraphics

// Pure geometry and persisted settings. All rectangles use Accessibility's
// global, top-left coordinate system, in points (never backing pixels).
enum WMUnit: String, Codable, CaseIterable { case percent, points }
struct WMMeasure: Codable, Equatable {
    var value: Double
    var unit: WMUnit
    func resolve(_ length: CGFloat) -> CGFloat {
        unit == .percent ? length * value / 100 : value
    }
    static func percent(_ value: Double) -> Self { .init(value: value, unit: .percent) }
    static func points(_ value: Double) -> Self { .init(value: value, unit: .points) }
}
enum WMAnchor: String, Codable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var fractions: CGPoint {
        switch self {
        case .topLeft: return .init(x: 0, y: 0)
        case .top: return .init(x: 0.5, y: 0)
        case .topRight: return .init(x: 1, y: 0)
        case .left: return .init(x: 0, y: 0.5)
        case .center: return .init(x: 0.5, y: 0.5)
        case .right: return .init(x: 1, y: 0.5)
        case .bottomLeft: return .init(x: 0, y: 1)
        case .bottom: return .init(x: 0.5, y: 1)
        case .bottomRight: return .init(x: 1, y: 1)
        }
    }
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        default: return rawValue.capitalized
        }
    }
}
enum WMDisplay: String, Codable, CaseIterable {
    case window, cursor, primary, next, previous
    var title: String {
        switch self {
        case .window: return "Window's display"
        case .cursor: return "Display under pointer"
        case .primary: return "Main display"
        case .next: return "Next display"
        case .previous: return "Previous display"
        }
    }
}
struct WMPlacement: Codable, Equatable {
    var width: WMMeasure? = .percent(50)
    var height: WMMeasure? = .percent(100)
    var anchor: WMAnchor = .left
    var offsetX: WMMeasure = .points(0)
    var offsetY: WMMeasure = .points(0)
    var display: WMDisplay = .window
    var displayID: UInt32? = nil
    var useGaps = true
}
struct WMShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    // Carbon modifier bits, persisted independently of keyboard layout.
    var modifiers: UInt32
}
enum WMOperation: String, Codable {
    case placement, reasonable, grow, shrink, nextDisplay, previousDisplay, undo, redo, fullscreen
}
struct WMCommand: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var operation: WMOperation = .placement
    var placement: WMPlacement = .init()
    var shortcut: WMShortcut? = nil
    var enabled = true
    var builtIn = false
    var alias = ""
}
struct WMSceneWindow: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var bundleID: String
    var appName: String
    // Exact title is an optional local matching hint, never used as executable input.
    var title: String
    var ordinal: Int
    var placement: WMPlacement
}
struct WMScene: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var windows: [WMSceneWindow]
    var shortcut: WMShortcut? = nil
}
struct WMConfiguration: Codable, Equatable {
    var version = 1
    var enabled = true
    var outerGap: Double = 0
    var innerGap: Double = 0
    var resizeStep: Double = 40
    var cycleHalves = false
    var repeatedHalfMovesDisplay = true
    var commands = WMCommand.defaults
    var scenes: [WMScene] = []

    func validated() throws -> Self {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw WMValidationError(message: message) }
        }
        try require(version == 1, "This settings version is not supported.")
        try require(outerGap.isFinite && (0...100).contains(outerGap), "Outer gap must be between 0 and 100 points.")
        try require(innerGap.isFinite && (0...100).contains(innerGap), "Inner gap must be between 0 and 100 points.")
        try require(resizeStep.isFinite && (1...500).contains(resizeStep), "Resize step must be between 1 and 500 points.")
        try require(commands.count <= 250 && scenes.count <= 100, "Use at most 250 commands and 100 layouts.")
        try require(Set(commands.map(\.id)).count == commands.count, "Command identifiers must be unique.")
        try require(Set(scenes.map(\.id)).count == scenes.count, "Layout identifiers must be unique.")
        var shortcuts = Set<WMShortcut>()
        func validateShortcut(_ shortcut: WMShortcut?, _ name: String) throws {
            guard let s = shortcut else { return }
            let allowed: UInt32 = 256 | 512 | 2048 | 4096
            try require(s.keyCode <= 127 && s.modifiers & ~allowed == 0, "Invalid shortcut for \(name).")
            try require(s.modifiers & (256 | 2048 | 4096) != 0, "Shortcuts need Command, Option, or Control.")
            try require(!(s.keyCode == 48 && (s.modifiers & 256 != 0 || s.modifiers == 2048 || s.modifiers == 2560)), "Tab shortcuts are reserved for window switching.")
            try require(shortcuts.insert(s).inserted, "Two enabled actions use the same shortcut (\(name)).")
        }
        func validatePlacement(_ p: WMPlacement) throws {
            for m in [p.width, p.height].compactMap({ $0 }) {
                try require(m.value.isFinite && m.value > 0 && m.value <= (m.unit == .percent ? 100 : 30000), "Size must be 1–100% or up to 30,000 points.")
            }
            for m in [p.offsetX, p.offsetY] {
                try require(m.value.isFinite && abs(m.value) <= (m.unit == .percent ? 100 : 30000), "Offsets must be within ±100% or ±30,000 points.")
            }
        }
        for command in commands {
            try require(!command.id.isEmpty && !command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Every command needs a name and identifier.")
            try validatePlacement(command.placement)
            if command.enabled { try validateShortcut(command.shortcut, command.name) }
        }
        for scene in scenes {
            try require(!scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Every layout needs a name.")
            try require(!scene.windows.isEmpty && scene.windows.count <= 64, "A layout needs 1–64 windows.")
            try validateShortcut(scene.shortcut, scene.name)
            for window in scene.windows {
                try require(!window.bundleID.isEmpty && window.ordinal >= 0, "Layout window has no app or an invalid index.")
                try validatePlacement(window.placement)
            }
        }
        return self
    }
}
struct WMValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension WMCommand {
    static var defaults: [WMCommand] {
        let co: UInt32 = 4096 | 2048
        func placement(_ id: String, _ name: String, _ w: Double?, _ h: Double?, _ anchor: WMAnchor, key: UInt32? = nil, x: Double = 0, y: Double = 0) -> WMCommand {
            .init(id: id, name: name, placement: .init(width: w.map(WMMeasure.percent), height: h.map(WMMeasure.percent), anchor: anchor, offsetX: .percent(x), offsetY: .percent(y)), shortcut: key.map { .init(keyCode: $0, modifiers: co) }, builtIn: true)
        }
        var commands = [
            placement("left-half", "Left Half", 50, 100, .left, key: 123),
            placement("right-half", "Right Half", 50, 100, .right, key: 124),
            placement("maximize", "Maximize", 100, 100, .center, key: 36),
            placement("center", "Center", nil, nil, .center, key: 8),
            placement("top-half", "Top Half", 100, 50, .top),
            placement("bottom-half", "Bottom Half", 100, 50, .bottom),
            placement("top-left", "Top Left Quarter", 50, 50, .topLeft, key: 32),
            placement("top-right", "Top Right Quarter", 50, 50, .topRight, key: 34),
            placement("bottom-left", "Bottom Left Quarter", 50, 50, .bottomLeft, key: 38),
            placement("bottom-right", "Bottom Right Quarter", 50, 50, .bottomRight, key: 40),
            placement("first-third", "First Third", 100/3, 100, .left, key: 2),
            placement("center-third", "Center Third", 100/3, 100, .center, key: 3),
            placement("last-third", "Last Third", 100/3, 100, .right, key: 5),
            placement("first-two-thirds", "First Two Thirds", 200/3, 100, .left, key: 14),
            placement("last-two-thirds", "Last Two Thirds", 200/3, 100, .right, key: 17),
            placement("first-fourth", "First Fourth", 25, 100, .left),
            placement("second-fourth", "Second Fourth", 25, 100, .left, x: 25),
            placement("third-fourth", "Third Fourth", 25, 100, .left, x: 50),
            placement("last-fourth", "Last Fourth", 25, 100, .right),
            placement("top-left-sixth", "Top Left Sixth", 100/3, 50, .topLeft),
            placement("top-center-sixth", "Top Center Sixth", 100/3, 50, .top),
            placement("top-right-sixth", "Top Right Sixth", 100/3, 50, .topRight),
            placement("bottom-left-sixth", "Bottom Left Sixth", 100/3, 50, .bottomLeft),
            placement("bottom-center-sixth", "Bottom Center Sixth", 100/3, 50, .bottom),
            placement("bottom-right-sixth", "Bottom Right Sixth", 100/3, 50, .bottomRight),
            placement("maximize-width", "Maximize Width", 100, nil, .center),
            placement("maximize-height", "Maximize Height", nil, 100, .center),
            placement("move-left", "Move Left", nil, nil, .left),
            placement("move-right", "Move Right", nil, nil, .right),
            placement("move-up", "Move Up", nil, nil, .top),
            placement("move-down", "Move Down", nil, nil, .bottom)
        ]
        for (id, name, op, key, mods) in [
            ("reasonable-size", "Reasonable Size", WMOperation.reasonable, Optional<UInt32>(51), co),
            ("next-display", "Next Display", .nextDisplay, 124, co | 256),
            ("previous-display", "Previous Display", .previousDisplay, 123, co | 256),
            ("grow", "Make Larger", .grow, nil, co),
            ("shrink", "Make Smaller", .shrink, nil, co),
            ("undo", "Restore Previous Bounds", .undo, 6, co),
            ("redo", "Redo Window Move", .redo, 6, co | 512),
            ("fullscreen", "Toggle Fullscreen", .fullscreen, nil, co)
        ] {
            commands.append(.init(id: id, name: name, operation: op, shortcut: key.map { .init(keyCode: $0, modifiers: mods) }, builtIn: true))
        }
        commands.append(.init(id: "chat-window", name: "Chat Window", placement: .init(width: .points(800), height: .points(1000), anchor: .center, useGaps: false), shortcut: .init(keyCode: 125, modifiers: co)))
        return commands
    }
}

struct WMScreen: Equatable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let visible: CGRect
}
enum WMGeometry {
    static func fromAppKit(_ r: CGRect, primaryTop: CGFloat) -> CGRect {
        .init(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
    }
    static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance && abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
    static func screen(for window: CGRect, screens: [WMScreen]) -> WMScreen? {
        screens.max { a, b in
            let ar = a.frame.intersection(window), br = b.frame.intersection(window)
            let aa = ar.isNull ? 0 : ar.width * ar.height
            let ba = br.isNull ? 0 : br.width * br.height
            if aa != ba { return aa < ba }
            return hypot(a.frame.midX-window.midX, a.frame.midY-window.midY) > hypot(b.frame.midX-window.midX, b.frame.midY-window.midY)
        }
    }
    static func destination(_ p: WMPlacement, source: WMScreen, screens: [WMScreen], cursor: CGPoint) -> WMScreen {
        if let id = p.displayID, let found = screens.first(where: { $0.id == id }) { return found }
        switch p.display {
        case .window: return source
        case .primary: return screens.first ?? source
        case .cursor: return screens.first(where: { $0.frame.contains(cursor) }) ?? source
        case .next, .previous:
            let ordered = screens.sorted { a, b in
                a.frame.minX == b.frame.minX ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
            }
            guard let i = ordered.firstIndex(where: { $0.id == source.id }), !ordered.isEmpty else { return source }
            return ordered[(i + (p.display == .next ? 1 : ordered.count-1)) % ordered.count]
        }
    }
    static func clamp(_ r: CGRect, inside screen: CGRect) -> CGRect {
        let size = CGSize(width: min(max(1,r.width),screen.width), height: min(max(1,r.height),screen.height))
        return .init(x: min(max(r.minX, screen.minX), screen.maxX-size.width), y: min(max(r.minY, screen.minY),screen.maxY-size.height), width: size.width, height: size.height)
    }
    static func placement(_ p: WMPlacement, current: CGRect, screen: CGRect, outer: Double, inner: Double) -> CGRect {
        let anchor = p.anchor.fractions
        var r = CGRect(x: 0, y: 0, width: p.width?.resolve(screen.width) ?? current.width, height: p.height?.resolve(screen.height) ?? current.height)
        r.origin = .init(x: screen.minX + (screen.width-r.width)*anchor.x + p.offsetX.resolve(screen.width), y: screen.minY + (screen.height-r.height)*anchor.y + p.offsetY.resolve(screen.height))
        r = clamp(r, inside: screen)
        if p.useGaps {
            // Each interior edge contributes half the shared gap; outer edges
            // use the full desktop inset. Adjacent tiles have one gap, not two.
            if p.width != nil {
                let left = abs(r.minX-screen.minX) < 1 ? outer : inner/2
                let right = abs(r.maxX-screen.maxX) < 1 ? outer : inner/2
                r.origin.x += left; r.size.width = max(1,r.width-left-right)
            }
            if p.height != nil {
                let top = abs(r.minY-screen.minY) < 1 ? outer : inner/2
                let bottom = abs(r.maxY-screen.maxY) < 1 ? outer : inner/2
                r.origin.y += top; r.size.height = max(1,r.height-top-bottom)
            }
        }
        return clamp(CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded()), inside: screen)
    }
    static func moveDisplay(_ r: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let nx = (r.minX-source.minX)/source.width, ny = (r.minY-source.minY)/source.height
        return clamp(.init(x: target.minX+nx*target.width, y: target.minY+ny*target.height,
                           width: r.width/source.width*target.width, height: r.height/source.height*target.height), inside: target)
    }
    static func frame(_ c: WMCommand, current: CGRect, source: CGRect, target: CGRect, config: WMConfiguration, cycle: Int = 0) -> CGRect {
        switch c.operation {
        case .placement:
            var p = c.placement
            if config.cycleHalves && ["left-half","right-half"].contains(c.id) {
                p.width = .percent([50,200.0/3,100.0/3][cycle % 3])
            }
            var result = placement(p, current: current, screen: target, outer: config.outerGap, inner: config.innerGap)
            // Width/height maximization and edge moves preserve the other axis.
            if c.id == "maximize-width" || c.id == "move-left" || c.id == "move-right" { result.origin.y = current.minY }
            if c.id == "maximize-height" || c.id == "move-up" || c.id == "move-down" { result.origin.x = current.minX }
            return clamp(result, inside: target)
        case .reasonable:
            return placement(.init(width: .points(min(1025,target.width*0.6)), height: .points(min(900,target.height*0.6)), anchor: .center, useGaps: false), current: current, screen: target, outer: 0, inner: 0)
        case .grow, .shrink:
            let step = config.resizeStep * (c.operation == .grow ? 1 : -1)
            let width = max(100,current.width+step), height = max(100,current.height+step)
            return clamp(.init(x: current.midX-width/2, y: current.midY-height/2, width: width, height: height), inside: target)
        case .nextDisplay, .previousDisplay:
            return moveDisplay(current, from: source, to: target)
        case .undo, .redo, .fullscreen: return current
        }
    }
    // An app can enforce a larger minimum size. Preserve the intended edge or
    // center alignment using the size it actually accepted, keeping its title bar visible.
    static func alignAcceptedSize(_ actual: CGSize, desired: CGRect, anchor: WMAnchor, screen: CGRect) -> CGPoint {
        let f = anchor.fractions
        let x = desired.minX + (desired.width-actual.width)*f.x
        let y = desired.minY + (desired.height-actual.height)*f.y
        return .init(x: max(screen.minX,min(x,screen.maxX-actual.width)), y: max(screen.minY,min(y,screen.maxY-actual.height)))
    }
}
