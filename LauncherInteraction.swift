import SwiftUI

/// A real drag gesture exists only on empty composer/header regions.
/// Buttons and menu rows cannot start moving the panel.
struct LauncherDragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:4,coordinateSpace:.global)
            .onChanged { LauncherController.shared.dragBody(translation:$0.translation) }
            .onEnded { _ in LauncherController.shared.endBodyDrag() })
            .accessibilityHidden(true)
    }
}
struct LauncherHoverStyle: ButtonStyle {
    var horizontal: CGFloat = 0
    var vertical: CGFloat = 0
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration:configuration,horizontal:horizontal,vertical:vertical,radius:radius)
    }
    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        let horizontal: CGFloat
        let vertical: CGFloat
        let radius: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal,horizontal).padding(.vertical,vertical)
                .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.10 : enabled && hovered ? 0.055 : 0),in:RoundedRectangle(cornerRadius:radius))
                .contentShape(RoundedRectangle(cornerRadius:radius)).onHover { hovered = $0 }
        }
    }
}
