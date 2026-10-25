import AdbKit
import SwiftUI
import UIKit

/// Invisible first responder that forwards every typed character to the TV
/// as it is typed (software keyboard or a hardware keyboard).
struct KeyCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onDelete: () -> Void
    let onSpecial: (Keycode) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onText = onText
        view.onDelete = onDelete
        view.onSpecial = onSpecial
        view.onResign = { if isActive { isActive = false } }
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onText = onText
        view.onDelete = onDelete
        view.onSpecial = onSpecial
        view.onResign = { if isActive { isActive = false } }
        DispatchQueue.main.async {
            if isActive, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !isActive, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onSpecial: (Keycode) -> Void = { _ in }
    var onResign: () -> Void = {}

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onResign()
        return result
    }

    // Keep the keyboard plain: no autocorrect or smart punctuation rewriting what we send.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .send

    var hasText: Bool { true } // so backspace always reaches deleteBackward

    func insertText(_ text: String) { onText(text) }
    func deleteBackward() { onDelete() }

    // Hardware keyboard keys that don't produce text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let mapped: Keycode? = switch key.keyCode {
            case .keyboardUpArrow: .dpadUp
            case .keyboardDownArrow: .dpadDown
            case .keyboardLeftArrow: .dpadLeft
            case .keyboardRightArrow: .dpadRight
            case .keyboardEscape: .back
            case .keyboardTab: .tab
            case .keyboardHome: .moveHome
            case .keyboardEnd: .moveEnd
            case .keyboardPageUp: .pageUp
            case .keyboardPageDown: .pageDown
            case .keyboardDeleteForward: .forwardDel
            default: nil
            }
            if let mapped {
                onSpecial(mapped)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}
