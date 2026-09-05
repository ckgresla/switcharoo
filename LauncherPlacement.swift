import Foundation
import CoreGraphics

/// Relative top anchor keeps the modal in place when its height changes.
struct LauncherPosition: Codable, Equatable {
    let displayID: UInt32
    let centerX: Double
    let top: Double
    init(frame: CGRect,screen: CGRect,displayID: UInt32) {
        self.displayID = displayID
        centerX = (frame.midX-screen.minX)/max(1,screen.width)
        top = (screen.maxY-frame.maxY)/max(1,screen.height)
    }
    func frame(size: CGSize,on screen: CGRect) -> CGRect {
        let x = screen.minX + min(1,max(0,centerX))*screen.width-size.width/2
        let y = screen.maxY-min(1,max(0,top))*screen.height-size.height
        return LauncherPlacement.clamp(CGRect(origin:CGPoint(x:x,y:y),size:size),to:screen)
    }
}
enum LauncherPlacement {
    static let guideFractions: [CGFloat] = [1/3,1/2,2/3]
    static func clamp(_ frame: CGRect,to screen: CGRect) -> CGRect {
        let width = min(frame.width,max(1,screen.width-32)),height = min(frame.height,max(1,screen.height-48))
        return CGRect(x:min(max(frame.minX,screen.minX+16),screen.maxX-16-width),y:min(max(frame.minY,screen.minY+24),screen.maxY-24-height),width:width,height:height)
    }
    static func snap(_ frame: CGRect,to screen: CGRect,tolerance: CGFloat = 18) -> CGRect {
        var result = frame
        if let x = guideFractions.map({screen.minX+screen.width*$0}).min(by:{abs($0-frame.midX)<abs($1-frame.midX)}),abs(x-frame.midX)<=tolerance { result.origin.x = x-frame.width/2 }
        if let y = guideFractions.map({screen.minY+screen.height*$0}).min(by:{abs($0-frame.midY)<abs($1-frame.midY)}),abs(y-frame.midY)<=tolerance { result.origin.y = y-frame.height/2 }
        return clamp(result,to:screen)
    }
}

/// Geometry is derived from the compact composer, never from an expanded frame.
/// AppKit coordinates increase upward. The composer is stationary in both modes.
struct LauncherExpansion: Equatable {
    let frame: CGRect
    let bar: CGRect
    let upward: Bool
    init(bar proposed: CGRect,preferredHeight: CGFloat,screen: CGRect) {
        let bar = LauncherPlacement.clamp(proposed,to:screen)
        let below = max(0,bar.minY-screen.minY-24)
        let above = max(0,screen.maxY-24-bar.maxY)
        // Pick a stable direction for this placement, including while compact.
        // Reserving the largest tool size avoids flipping sides as queries change.
        upward = below < max(0,620-bar.height) && above > below
        let extra = min(max(0,preferredHeight-bar.height),upward ? above : below)
        self.bar = bar
        frame = CGRect(x:bar.minX,y:upward ? bar.minY : bar.minY-extra,width:bar.width,height:bar.height+extra)
    }
}
