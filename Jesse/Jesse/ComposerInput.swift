import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The composer's text input, a `UITextView` bridged into SwiftUI.
//
// It replaces the SwiftUI `TextField` so the composer gets the NATIVE paste path:
// long-press → the system edit menu → "Paste", shown by iOS itself whenever the
// clipboard has content the field accepts. There is no custom paste button. When
// the clipboard holds a photo or a PDF, Paste stages it as an attachment (via
// `onPasteMedia`); a text clipboard pastes as text. This matches how paste behaves
// everywhere else on iOS — copy a photo in Photos, long-press here, Paste.
//
// It keeps the prior composer behavior: a multi-line floor (`minLines`) that never
// collapses to one line, growth to `maxLines` then internal scrolling, a
// placeholder, Dynamic Type, and a rounded border.
struct ComposerInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var minLines: Int
    var maxLines: Int
    /// Stage any image/PDF currently on the clipboard as attachments. Returns true
    /// iff it handled the paste, in which case the text view does NOT also paste
    /// text. Called on the main actor from the text view's `paste(_:)`.
    var onPasteMedia: () -> Bool

    func makeUIView(context: Context) -> PasteInterceptingTextView {
        let view = PasteInterceptingTextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.isScrollEnabled = true

        view.layer.cornerRadius = 8
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor

        view.pasteMediaHandler = { onPasteMedia() }

        // Placeholder shown while empty (a `UITextView` has none of its own).
        let placeholderLabel = UILabel()
        placeholderLabel.font = view.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        view.placeholderLabel = placeholderLabel
        view.addSubview(placeholderLabel)

        return view
    }

    func updateUIView(_ view: PasteInterceptingTextView, context: Context) {
        // Keep the coordinator's bindings/closures pointing at the current struct.
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        view.pasteMediaHandler = { onPasteMedia() }
        view.placeholderLabel?.text = placeholder
        view.placeholderLabel?.isHidden = !text.isEmpty
        view.layoutPlaceholder()

        // Drive first-responder from the SwiftUI focus binding, deferred so we
        // never mutate responder state during a view-update pass.
        DispatchQueue.main.async {
            if isFocused, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !isFocused, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PasteInterceptingTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let line = view.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let vInset = view.textContainerInset.top + view.textContainerInset.bottom
        let minHeight = ceil(line * CGFloat(minLines) + vInset)
        let maxHeight = ceil(line * CGFloat(maxLines) + vInset)
        let content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(content, minHeight), maxHeight)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerInput

        init(_ parent: ComposerInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? PasteInterceptingTextView)?.placeholderLabel?.isHidden = !textView.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// A `UITextView` that offers the native Paste edit-menu item for images and PDFs
/// (not just text) and routes such a paste to `pasteMediaHandler` — which stages
/// the clipboard media as attachments — instead of inserting bytes into the text.
final class PasteInterceptingTextView: UITextView {
    /// Stage clipboard image/PDF media as attachments. Returns true iff it handled
    /// the paste (so text isn't also pasted). Set by the representable each update.
    var pasteMediaHandler: (() -> Bool)?

    /// The placeholder label, laid out inside the text container inset.
    weak var placeholderLabel: UILabel?

    private var clipboardHasPDF: Bool {
        UIPasteboard.general.contains(pasteboardTypes: [UTType.pdf.identifier])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Offer Paste whenever the clipboard has anything the field accepts —
            // text, an image, or a PDF. iOS decides availability from the actual
            // clipboard contents; we don't gate it on our own state.
            let pb = UIPasteboard.general
            return pb.hasStrings || pb.hasImages || clipboardHasPDF
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // A copied photo or PDF stages as an attachment; anything else (text) uses
        // the native text paste.
        let pb = UIPasteboard.general
        if ComposerPaste.isMediaPaste(hasImages: pb.hasImages, hasPDF: clipboardHasPDF),
           pasteMediaHandler?() == true {
            return
        }
        super.paste(sender)
    }

    /// Position the placeholder at the text origin (inside the container inset).
    func layoutPlaceholder() {
        guard let label = placeholderLabel else { return }
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        let y = textContainerInset.top
        let width = bounds.width - x - textContainerInset.right - textContainer.lineFragmentPadding
        let size = label.sizeThatFits(CGSize(width: max(width, 0), height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: x, y: y, width: max(width, 0), height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlaceholder()
    }
}
