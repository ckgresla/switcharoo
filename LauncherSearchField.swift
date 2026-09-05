import AppKit
import SwiftUI

/// Use the same AppKit field editor and steady native caret as Option-Tab.
struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusGeneration: Int
    let move: (Int) -> Void
    let submit: (NSEvent.ModifierFlags) -> Void
    let escape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField(frame:.zero)
        field.cell = CenteredSearchCell(textCell: "")
        field.identifier = NSUserInterfaceItemIdentifier("launcher-search")
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.isEditable = true; field.isSelectable = true; field.usesSingleLineMode = true
        field.cell?.wraps = false; field.cell?.isScrollable = true
        field.font = SwitcharooSearchMetrics.font
        field.setAccessibilityLabel("Search apps and commands")
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: SearchField,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? nsView.frame.width,height:SwitcharooSearchMetrics.fieldHeight)
    }
    func updateNSView(_ field: SearchField,context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = .labelColor
        field.placeholderString = ""
        if context.coordinator.focusGeneration != focusGeneration {
            context.coordinator.focusGeneration = focusGeneration
            DispatchQueue.main.async { [weak field] in
                guard let field,let window = field.window,window.isVisible,window.isKeyWindow else { return }
                window.makeFirstResponder(field)
            }
        }
    }
    final class Coordinator: NSObject,NSTextFieldDelegate {
        var parent: LauncherSearchField
        var focusGeneration: Int?
        init(_ parent: LauncherSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl,textView: NSTextView,doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.move(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.submit(NSApp.currentEvent?.modifierFlags ?? []); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.escape(); return true
            default: return false
            }
        }
    }
}
