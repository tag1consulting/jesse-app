import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// A TEXT BOX THAT DOES NOT HELP.
//
// Every convenience a modern text view turns on by default is a bug in a markdown editor,
// and they are bugs of the worst kind: they change characters silently, in a file format
// where the character IS the meaning.
//
//     "  becomes  “ ”     and a fenced code block stops compiling
//     --  becomes  –      and a command line stops working
//     ...  becomes  …     and a grep for it stops matching
//     capitalising "i"    and a wiki link stops resolving
//
// SwiftUI's `TextEditor` has no modifier for ANY of those four on macOS — the substitution
// flags live on `NSTextView` and are not surfaced — so this is a representable rather than
// a `TextEditor` with modifiers hung off it. That is the whole reason it exists; the
// keystroke budget is a second reason it stays. See the pull request for the measurement.
//
// The other job it does is the one every representable has to get right: it must not fight
// the person typing. `updateUIView` writes the model's text into the view ONLY when they
// differ, because assigning a `UITextView`'s text unconditionally on every SwiftUI update
// resets the selection to the end of the document — which on a long note means the cursor
// jumps away mid-word, once per keystroke.

/// The file's own text, monospaced, with every automatic substitution off.
public struct VaultPlainTextEditor: View {
    @Binding private var text: String
    /// Bumped by the owner when it replaces the text programmatically (a Reload, a
    /// restored stash), so the view can reset its undo stack rather than let an undo walk
    /// back into a document that no longer exists.
    private let resetToken: Int

    public init(text: Binding<String>, resetToken: Int = 0) {
        _text = text
        self.resetToken = resetToken
    }

    public var body: some View {
        Representable(text: $text, resetToken: resetToken)
    }
}

#if os(iOS)

extension VaultPlainTextEditor {
    struct Representable: UIViewRepresentable {
        @Binding var text: String
        let resetToken: Int

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.delegate = context.coordinator
            view.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
            // THE FOUR, OFF.
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.spellCheckingType = .no
            // NOT `.asciiCapable`, which was the first version and is wrong: this vault is
            // half in Italian, and a keyboard that cannot type “però” is worse than any
            // substitution it would have prevented. The substitutions are off above; the
            // alphabet is none of this view's business.
            view.keyboardType = .default
            view.alwaysBounceVertical = true
            view.backgroundColor = .clear
            view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            view.text = text
            context.coordinator.token = resetToken
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            if context.coordinator.token != resetToken {
                context.coordinator.token = resetToken
                view.text = text
                // The undo stack describes edits to text that is no longer in the view;
                // an undo against it is the `NSRangeException` this app has met before.
                view.undoManager?.removeAllActions()
                return
            }
            // ONLY when they differ — see the file comment on the jumping cursor.
            if view.text != text { view.text = text }
        }

        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate {
            @Binding var text: String
            var token = 0

            init(text: Binding<String>) { _text = text }

            func textViewDidChange(_ textView: UITextView) {
                text = textView.text
            }
        }
    }
}

#elseif os(macOS)

extension VaultPlainTextEditor {
    struct Representable: NSViewRepresentable {
        @Binding var text: String
        let resetToken: Int

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            guard let view = scroll.documentView as? NSTextView else { return scroll }
            view.delegate = context.coordinator
            view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            // THE FOUR, OFF — plus `isRichText`, without which a paste carries the source's
            // fonts and colours into what has to end up as plain UTF-8 on disk.
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isAutomaticDataDetectionEnabled = false
            view.isAutomaticLinkDetectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.isGrammarCheckingEnabled = false
            view.allowsUndo = true
            view.textContainerInset = NSSize(width: 6, height: 8)
            view.string = text
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            view.drawsBackground = false
            context.coordinator.token = resetToken
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let view = scroll.documentView as? NSTextView else { return }
            if context.coordinator.token != resetToken {
                context.coordinator.token = resetToken
                view.string = text
                view.undoManager?.removeAllActions()
                return
            }
            if view.string != text { view.string = text }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            @Binding var text: String
            var token = 0

            init(text: Binding<String>) { _text = text }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                text = view.string
            }
        }
    }
}

#endif
