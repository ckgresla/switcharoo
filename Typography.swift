import AppKit
import SwiftUI

enum SwitcharooTypography {
    private static let cache = NSCache<NSString,NSFont>()
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = "\(size):\(weight.rawValue)" as NSString
        if let cached = cache.object(forKey:key) { return cached }
        func remember(_ font: NSFont) -> NSFont { cache.setObject(font,forKey:key); return font }
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Bold"
        case .semibold: face = "SemiBold"
        case .medium: face = "Medium"
        case .light: face = "Light"
        case .ultraLight, .thin: face = "Thin"
        default: face = "Regular"
        }
        if let font = NSFont(name: "Inter-\(face)",size: size) { return remember(font) }
        if let base = NSFont(name: "InterVariable",size: size) ?? NSFont(name: "Inter",size: size),
           let weighted = NSFont(descriptor: base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]]),size: size) { return remember(weighted) }
        return remember(.systemFont(ofSize: size,weight: weight))
    }
    static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> Font { Font(font(size: size,weight: weight)) }
}

/// Shared native search geometry for the launcher and Option-Tab.
enum SwitcharooSearchMetrics {
    static let panelWidth: CGFloat = 700
    static let rowHeight: CGFloat = 50
    static let fieldHeight: CGFloat = 30
    // NSTextField adds a 2-point glyph inset; visible text begins at x=25.
    static let leading: CGFloat = 23
    static let trailing: CGFloat = 18
    static let fontSize: CGFloat = 17
    static var font: NSFont { SwitcharooTypography.font(size:fontSize) }
}
