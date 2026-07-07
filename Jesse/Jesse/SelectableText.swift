import SwiftUI
import UIKit

// A non-editable, non-scrolling `UITextView` bridged into SwiftUI, rendering an
// `NSAttributedString`.
//
// Why not a SwiftUI `Text` with `.textSelection(.enabled)`: inside a scrolling
// transcript that gave all-or-nothing, whole-block selection — you couldn't drag
// the handles to grab individual words or sentences. A `UITextView` provides the
// real native text-interaction gestures: long-press to start a selection,
// double-tap for a word, drag the handles by word/sentence, Select All, and the
// system edit menu (Copy / Share …). Nothing custom intercepts the long-press.
//
// It sizes itself to its content at the proposed width (`isScrollEnabled = false`,
// height from `sizeThatFits`), so it drops into the block `VStack` like a `Text`.
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        // Links are tappable (attributed `.link` runs); no data-detector guessing.
        view.dataDetectorTypes = []
        // Hug content so the intrinsic height drives the SwiftUI layout rather than
        // the text view stretching to fill.
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != attributed {
            view.attributedText = attributed
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView,
                      context: Context) -> CGSize? {
        // A finite proposed width wraps the text; an absent/infinite one measures
        // the natural single-line width (short bubbles hug their content).
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? .greatestFiniteMagnitude
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(fitting.width, width), height: ceil(fitting.height))
    }
}
