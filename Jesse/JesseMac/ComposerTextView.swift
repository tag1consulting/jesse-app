import AppKit
import SwiftUI

// The macOS composer's text input: an `NSTextView` in an `NSScrollView`, wrapped for SwiftUI.
//
// It exists because a SwiftUI `TextField` cannot tell Return from Shift plus Return. The field
// consumes the key itself and reports it through `.onSubmit`, which carries no modifier state,
// so "send on Return, newline on Shift plus Return" is not expressible there at any level of
// cleverness. `NSTextView.keyDown(with:)` gets the whole `NSEvent`, modifiers included, which is
// the lowest layer that still knows whether the composer has focus.
//
// Two tempting shortcuts are wrong and were not used:
//   * `.keyboardShortcut(.return, modifiers: …)` cannot express "Return with any modifier", and a
//     shortcut competes with the focused text view for the key rather than cooperating with it.
//   * `NSEvent.addLocalMonitorForEvents` sees every key in the process regardless of focus, so it
//     would hijack Return in the sidebar, the search field, and every sheet in the app.
//
// Everything AppKit already gives a text view (paste, copy, cut, select all, undo and redo, spell
// check, autocorrect, dictation, the emoji palette, the Services menu, the context menu) keeps
// working because the only key this class intercepts is Return, and only when
// `composerKeyAction` says so.

/// The composer's text input. Grows with its content from `minLines` up to `maxLines`, then
/// scrolls. Return sends, Return with a modifier inserts a newline (see `composerKeyAction`).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// Drawn in place of the text when the composer is empty.
    var placeholder: String = ""
    /// Height floor and ceiling, in lines of the composer's font.
    var minLines: Int = 1
    var maxLines: Int = 8
    /// Whether to take focus when the composer first appears.
    var focusOnAppear: Bool = true
    /// Invoked for a plain Return. The gate on whether a send is ALLOWED is not here: this
    /// closure is the same `send()` the send button calls, and that function's guard (which the
    /// button's `disabled` state mirrors) stays the single source of truth.
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.placeholder = placeholder
        textView.string = text

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = ComposerNSTextView.composerFont
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Match a SwiftUI TextField: spell check and autocorrect on. Smart quote and smart dash
        // substitution stay OFF: a composer whose text goes to a coding agent must deliver what
        // was typed, and a curly quote or a substituted dash in a path or a code fence is a bug,
        // not a nicety.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none

        if focusOnAppear {
            // Once, on appearance, the way a chat window behaves. Deferred because the view has
            // no window yet during `makeNSView`.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                // Never yank focus off another text input the user is already typing in.
                if window.firstResponder is NSText || window.firstResponder is NSTextView { return }
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        // Refreshed every update, not captured once: the closure reads the view's current state,
        // so a stale one would send a stale draft.
        textView.onSend = onSend
        textView.placeholder = placeholder
        context.coordinator.apply(text, to: textView)
    }

    /// Report the composer's height: the laid-out text, clamped to the line floor and ceiling.
    /// Width is passed straight through so the field stays horizontally flexible in its HStack.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? ComposerNSTextView else { return nil }
        let width: CGFloat
        if let proposed = proposal.width, proposed > 0, proposed < .infinity {
            width = proposed
        } else {
            width = Self.idealWidth
        }
        let height = ComposerHeight.clamped(
            textHeight: textView.measuredTextHeight(forWidth: width),
            lineHeight: ComposerNSTextView.lineHeight,
            minLines: minLines,
            maxLines: maxLines,
            verticalInset: textView.textContainerInset.height * 2)
        return CGSize(width: width, height: height)
    }

    /// Only used to answer an unspecified or infinite width proposal; the call site's
    /// `maxWidth: .infinity` is what actually makes the field fill its row.
    private static let idealWidth: CGFloat = 240

    /// Bridges the text view's edits into the SwiftUI binding and back, without the caret
    /// jumping. The classic `NSViewRepresentable` defect is `updateNSView` writing the binding
    /// into the text view on every keystroke: assigning `string` collapses the selection, so the
    /// caret lands at the end and the user cannot type in the middle of their own message. The
    /// fix is `apply`'s equality guard, which makes the round trip of the view's OWN edit a
    /// no-op.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        /// The composer's OWN undo manager, deliberately not the window's.
        ///
        /// Two reasons, and the second one is a crash. First, the composer's edits are its own
        /// business and should not interleave with anything else in the window. Second, `apply`
        /// replaces the text wholesale (a completed send clears the draft) and such a replacement
        /// is NOT an undoable edit, so every undo action recorded before it now describes ranges
        /// in text that no longer exists. Undoing across that boundary throws `NSRangeException`
        /// ("Range {0, 5} out of bounds; string length 0") and takes the app down. Owning the
        /// stack is what makes it safe to clear at that exact moment.
        let composerUndoManager = UndoManager()

        init(text: Binding<String>) {
            self.text = text
        }

        func undoManager(for view: NSTextView) -> UndoManager? { composerUndoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
        }

        /// Push a SwiftUI-side value into the text view. Does nothing when the text view already
        /// holds it (the echo of its own edit), which is what keeps the selection intact.
        func apply(_ newValue: String, to textView: NSTextView) {
            guard textView.string != newValue else { return }
            let previous = textView.selectedRange()
            textView.string = newValue
            // An external change (a send clearing the draft, a restored value): keep the caret
            // where it was if that is still inside the new text, else put it at the end.
            let length = (newValue as NSString).length
            let location = min(previous.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // This replacement is not undoable, so nothing recorded before it can be undone
            // safely (see `composerUndoManager`). Start the composer's history fresh.
            composerUndoManager.removeAllActions()
            textView.needsDisplay = true
        }
    }
}

/// The height clamp, kept apart from the view so it can be tested directly. `nonisolated` for the
/// same reason as `composerKeyAction`: it is arithmetic, not UI state.
nonisolated enum ComposerHeight {
    /// The composer's height for text that lays out to `textHeight`: never shorter than
    /// `minLines`, never taller than `maxLines` (past which the text view scrolls).
    static func clamped(textHeight: CGFloat, lineHeight: CGFloat,
                        minLines: Int, maxLines: Int, verticalInset: CGFloat) -> CGFloat {
        let floor = lineHeight * CGFloat(max(minLines, 1))
        let ceiling = lineHeight * CGFloat(max(maxLines, max(minLines, 1)))
        return min(max(textHeight, floor), ceiling) + verticalInset
    }
}

/// The composer's `NSTextView`. Its whole job is the Return key; everything else is inherited.
final class ComposerNSTextView: NSTextView {
    /// Invoked when a key press means "send".
    var onSend: (() -> Void)?

    /// Drawn when the composer is empty. `NSTextView` has no placeholder of its own.
    var placeholder: String = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    static let composerFont = NSFont.preferredFont(forTextStyle: .body)
    /// One line of the composer's font, used for the height floor and ceiling.
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: composerFont))

    override func keyDown(with event: NSEvent) {
        switch composerKeyAction(keyCode: event.keyCode,
                                 modifiers: event.modifierFlags,
                                 hasMarkedText: hasMarkedText()) {
        case .send:
            onSend?()
        case .insertNewline:
            // Through the text input path rather than by rewriting `string`, so the newline is a
            // normal edit: one undo step, current typing attributes, marked text respected.
            insertText("\n", replacementRange: selectedRange())
            scrollRangeToVisible(selectedRange())
        case .passThrough:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder appears and disappears with emptiness.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Self.composerFont,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// How tall the current text lays out at `width`, before clamping.
    func measuredTextHeight(forWidth width: CGFloat) -> CGFloat {
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        let usable = max(width - textContainerInset.width * 2 - padding, 1)
        // A trailing newline opens a line that `boundingRect` does not measure, so the composer
        // would not grow until the next character. Measure a sentinel on that line instead.
        let measured = string.hasSuffix("\n") ? string + " " : string
        guard !measured.isEmpty else { return Self.lineHeight }
        let rect = (measured as NSString).boundingRect(
            with: CGSize(width: usable, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font ?? Self.composerFont])
        return ceil(rect.height)
    }
}
