import Foundation
import CoreGraphics
@main struct PlacementTests {
 static func main() throws {
  var checks = 0
  func check(_ value:Bool,_ label:String) { checks += 1; if !value { fatalError(label) } }
  let display = CGRect(x:-1920,y:-400,width:1920,height:1080)
  let bar = CGRect(x:-1500,y:400,width:700,height:110)
  let saved = LauncherPosition(frame:bar,screen:display,displayID:42)
  check(saved.frame(size:bar.size,on:display) == bar,"round trip on negative-origin display")
  let open = saved.frame(size:CGSize(width:700,height:430),on:display)
  check(open.maxY == bar.maxY && open.midX == bar.midX,"expand down at saved anchor")
  let restored = try JSONDecoder().decode(LauncherPosition.self,from:JSONEncoder().encode(saved))
  check(saved == restored,"position persistence")
  let smaller = CGRect(x:0,y:0,width:1024,height:768)
  let moved = restored.frame(size:CGSize(width:700,height:620),on:smaller)
  check(smaller.contains(moved),"disconnected display fallback stays on screen")
  let near = CGRect(x:display.midX-350+8,y:display.midY-55+6,width:700,height:110)
  let snapped = LauncherPlacement.snap(near,to:display)
  check(snapped.midX == display.midX && snapped.midY == display.midY,"snap near alignment guides")
  let far = CGRect(x:-1670,y:420,width:700,height:110)
  check(LauncherPlacement.snap(far,to:display) == far,"free placement away from guides")
  let offscreen = LauncherPlacement.clamp(CGRect(x:2000,y:-9999,width:700,height:110),to:display)
  check(display.contains(offscreen),"clamp offscreen drag")
  let oversized = LauncherPlacement.clamp(CGRect(x:0,y:0,width:700,height:620),to:CGRect(x:0,y:0,width:600,height:500))
  check(oversized.width == 568 && oversized.height == 452,"small display bounds")
  let desktop = CGRect(x:0,y:0,width:1440,height:1000)
  let highBar = CGRect(x:370,y:740,width:700,height:110)
  let lowBar = CGRect(x:370,y:80,width:700,height:110)
  for (anchor,up) in [(highBar,false),(lowBar,true)] {
    for height: CGFloat in [110,258,450,620,258,110] {
      let expansion = LauncherExpansion(bar:anchor,preferredHeight:height,screen:desktop)
      check(expansion.bar == anchor,"composer never moves while resizing")
      check(expansion.upward == up,"direction stays stable across result sizes")
      check(up ? expansion.frame.minY == anchor.minY : expansion.frame.maxY == anchor.maxY,"correct fixed edge")
      check(desktop.contains(expansion.frame),"expanded content stays on display")
    }
    let savedAnchor = LauncherPosition(frame:anchor,screen:desktop,displayID:7)
    let reopened = LauncherExpansion(bar:savedAnchor.frame(size:anchor.size,on:desktop),preferredHeight:620,screen:desktop)
    check(reopened.bar == anchor,"reopening restores compact anchor, not expanded bounds")
  }
  let middle = CGRect(x:370,y:445,width:700,height:110)
  let limited = LauncherExpansion(bar:middle,preferredHeight:620,screen:desktop)
  check(limited.bar == middle && limited.frame.height < 620,"constrain content instead of shifting anchor when neither side fits")
  let otherDisplay = CGRect(x:-1440,y:-1100,width:1440,height:1000)
  let otherLow = lowBar.offsetBy(dx:-1440,dy:-1100)
  let negative = LauncherExpansion(bar:otherLow,preferredHeight:620,screen:otherDisplay)
  check(negative.upward && negative.bar == otherLow && otherDisplay.contains(negative.frame),"upward expansion on negative-coordinate screen")
  let tiny = LauncherExpansion(bar:lowBar,preferredHeight:620,screen:CGRect(x:0,y:0,width:600,height:400))
  check(tiny.frame.width == 568 && CGRect(x:0,y:0,width:600,height:400).contains(tiny.frame),"small screen clips content, preserving a visible composer")
  for barHeight: CGFloat in [50,86,90] {
  for y: CGFloat in [80,740] {
    let search = CGRect(x:370,y:y,width:700,height:barHeight)
    for height: CGFloat in [50,86,438,474,198,86,50] {
      let layout = LauncherExpansion(bar:search,preferredHeight:height,screen:desktop)
      check(layout.bar == search,"50-point input stays anchored when pins or footer appear")
      check(layout.frame.width == 700,"pins and open mode preserve width")
      check(layout.upward ? layout.frame.minY == search.minY : layout.frame.maxY == search.maxY,"input edge stays fixed with pins")
    }
  }
  }
  print("\(checks) launcher placement checks passed")
 }
}
