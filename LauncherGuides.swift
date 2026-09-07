import AppKit

/// Noninteractive overlays exist only for the duration of a user drag.
final class LauncherGuides {
    private var panels: [NSPanel] = []
    func show() {
        hide()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect:screen.visibleFrame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue-1)
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
            panel.contentView = GuideView(frame:CGRect(origin:.zero,size:screen.visibleFrame.size))
            panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    func update(frame: CGRect,screen: NSScreen?) {
        for panel in panels {
            guard let view = panel.contentView as? GuideView else { continue }
            let active = panel.frame == screen?.visibleFrame
            let center = CGPoint(x:frame.midX-panel.frame.minX,y:frame.midY-panel.frame.minY)
            view.activeX = active ? LauncherPlacement.guideFractions.map { view.bounds.width*$0 }.first { abs($0-center.x)<=18 } : nil
            view.activeY = active ? LauncherPlacement.guideFractions.map { view.bounds.height*$0 }.first { abs($0-center.y)<=18 } : nil
            view.needsDisplay = true
        }
    }
    func hide() { panels.forEach { $0.orderOut(nil) }; panels.removeAll() }
    private final class GuideView: NSView {
        var activeX: CGFloat?
        var activeY: CGFloat?
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
            func line(from start: CGPoint,to end: CGPoint,active: Bool) {
                let alpha: CGFloat = active ? (dark ? 0.5:0.35) : (dark ? 0.25:0.18)
                (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha).setStroke()
                let path = NSBezierPath(); path.lineWidth = active ? 1.5:1
                path.setLineDash([5,6],count:2,phase:0)
                path.move(to:start); path.line(to:end); path.stroke()
            }
            for fraction in LauncherPlacement.guideFractions {
                let x = bounds.width*fraction,y = bounds.height*fraction
                line(from:CGPoint(x:x,y:0),to:CGPoint(x:x,y:bounds.height),active:activeX == x)
                line(from:CGPoint(x:0,y:y),to:CGPoint(x:bounds.width,y:y),active:activeY == y)
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
