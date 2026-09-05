import AppKit

// Own windows use AppKit on the main thread. AX calls to the same process can
// bypass IPC and are unsafe on the external-window executor's background queue.
final class NativeWindowMoves {
    static let shared = NativeWindowMoves()
    private struct History {
        var undo: [CGRect] = [], redo: [CGRect] = []
        var last: CGRect?, command: String?
        var cycle = 0
    }
    private var history: [Int:History] = [:]
    func perform(_ command: WMCommand,target: WMTarget,screens: [WMScreen],cursor: CGPoint,config: WMConfiguration) -> WMOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        func outcome(_ message: String,_ failed: Bool = false) -> WMOutcome { .init(message: message,milliseconds: Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000,failed: failed) }
        guard let window = ToolWindowHost.shared.nativeWindow(target.windowID) else { return outcome("Choose a tool window first.",true) }
        if command.operation == .fullscreen { window.toggleFullScreen(nil); return outcome(command.name) }
        guard !window.styleMask.contains(.fullScreen) else { return outcome("Leave fullscreen before resizing this window.",true) }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let before = WMGeometry.fromAppKit(window.frame,primaryTop: top)
        guard let source = WMGeometry.screen(for: before,screens: screens) else { return outcome("No display is available.",true) }
        var record = history[window.windowNumber] ?? History()
        if let last = record.last,!WMGeometry.near(last,before) { record.command = nil; record.cycle = 0; record.redo = [] }
        var placement = command.placement
        if command.operation == .nextDisplay { placement.display = .next; placement.displayID = nil }
        if command.operation == .previousDisplay { placement.display = .previous; placement.displayID = nil }
        var destination = WMGeometry.destination(placement,source: source,screens: screens,cursor: cursor)
        let cycle = record.command == command.id ? record.cycle+1 : 0
        if record.command == command.id,["left-half","right-half"].contains(command.id),config.repeatedHalfMovesDisplay,(!config.cycleHalves || cycle%3 == 0) {
            placement.display = command.id == "left-half" ? .previous : .next
            destination = WMGeometry.destination(placement,source: source,screens: screens,cursor: cursor)
        }
        var desired = WMGeometry.frame(command,current: before,source: source.visible,target: destination.visible,config: config,cycle: cycle)
        if command.operation == .undo || command.operation == .redo {
            guard let frame = (command.operation == .undo ? record.undo : record.redo).last else { return outcome("No move to \(command.operation.rawValue).",true) }
            destination = WMGeometry.screen(for: frame,screens: screens) ?? source
            desired = WMGeometry.clamp(frame,inside: destination.visible)
        }
        let accepted = CGSize(width: max(window.minSize.width,desired.width),height: max(window.minSize.height,desired.height))
        desired.origin = WMGeometry.alignAcceptedSize(accepted,desired: desired,anchor: placement.anchor,screen: destination.visible); desired.size = accepted
        window.setFrame(.init(x: desired.minX,y: top-desired.maxY,width: desired.width,height: desired.height),display: true,animate: false)
        let after = WMGeometry.fromAppKit(window.frame,primaryTop: top)
        if !WMGeometry.near(before,after) {
            switch command.operation {
            case .undo: record.undo.removeLast(); record.redo.append(before)
            case .redo: record.redo.removeLast(); record.undo.append(before)
            default: record.undo.append(before); record.redo = []
            }
        }
        record.undo = Array(record.undo.suffix(30)); record.redo = Array(record.redo.suffix(30)); record.last = after; record.command = command.id; record.cycle = cycle
        history[window.windowNumber] = record
        return outcome(command.name)
    }
}
