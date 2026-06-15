import SwiftUI
import AppKit

/// NSViewRepresentable wrapper around NSTextField so the search field
/// behaves like a native Spotlight-style input (no focus ring, large font, no bezel).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search…"
    let onSubmit: () async -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 22, weight: .regular)
        tf.delegate = context.coordinator
        tf.bezelStyle = .squareBezel
        tf.isBordered = false
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        init(_ p: SearchField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Enter key
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                Task { await parent.onSubmit() }
                return true
            }
            return false
        }
    }
}
