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

// TWO THINGS CROSS THE BOUNDARY NOW, and both exist so a bar of buttons can mark up what
// somebody selected. The SELECTION goes out, because nothing above a representable can see
// it and "wrap these words in a highlight" is unanswerable without it. An EDIT comes in,
// carried by a token the way `resetToken` carries a reload, and it is applied through the
// text view's OWN undoable replace rather than by assigning `text`. That distinction is
// the whole reason the edit is a value and not a string swap: an assignment to `text`
// clears the undo stack's idea of the document (see above) and leaves a person who marked
// the wrong sentence with no way back, while an undoable replace is one press of undo.
//
// The edit is applied on the next turn of the main loop rather than inside the update pass
// itself. Applying it in place would have the delegate write the new text back into the
// binding WHILE SwiftUI is evaluating that same binding's owner, which is the "modifying
// state during view update" it warns about and is undefined behaviour rather than a style
// point. One hop later everything is ordinary: the replace fires the delegate, the
// delegate writes the binding, and the next update sees text that already matches.

/// The file's own text, monospaced, with every automatic substitution off.
public struct VaultPlainTextEditor: View {
    @Binding private var text: String
    /// Bumped by the owner when it replaces the text programmatically (a Reload, a
    /// restored stash), so the view can reset its undo stack rather than let an undo walk
    /// back into a document that no longer exists.
    private let resetToken: Int
    /// Where the caret is, or what is selected, in UTF-16 units. Written on every
    /// selection change; nil where the owner does not care, which is every call site that
    /// has no annotation bar.
    private let selectedRange: Binding<NSRange>?
    /// The edit to apply when `editToken` changes, and nothing at any other time.
    private let pendingEdit: VaultTextEdit?
    /// Bumped by the owner for each edit it wants applied. A token rather than the edit's
    /// own identity because the same mark applied twice in a row is two edits.
    private let editToken: Int

    public init(text: Binding<String>, resetToken: Int = 0,
                selectedRange: Binding<NSRange>? = nil,
                pendingEdit: VaultTextEdit? = nil, editToken: Int = 0) {
        _text = text
        self.resetToken = resetToken
        self.selectedRange = selectedRange
        self.pendingEdit = pendingEdit
        self.editToken = editToken
    }

    public var body: some View {
        Representable(text: $text, resetToken: resetToken, selectedRange: selectedRange,
                      pendingEdit: pendingEdit, editToken: editToken)
    }
}

#if os(iOS)

extension VaultPlainTextEditor {
    struct Representable: UIViewRepresentable {
        @Binding var text: String
        let resetToken: Int
        let selectedRange: Binding<NSRange>?
        let pendingEdit: VaultTextEdit?
        let editToken: Int

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, selection: selectedRange)
        }

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
            context.coordinator.editToken = editToken
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            if context.coordinator.token != resetToken {
                context.coordinator.token = resetToken
                context.coordinator.editToken = editToken
                view.text = text
                // The undo stack describes edits to text that is no longer in the view;
                // an undo against it is the `NSRangeException` this app has met before.
                view.undoManager?.removeAllActions()
                return
            }
            if context.coordinator.editToken != editToken {
                context.coordinator.editToken = editToken
                if let edit = pendingEdit {
                    // One hop out of the update pass: see the file comment.
                    let binding = $text
                    Task { @MainActor in
                        guard VaultPlainTextEditor.apply(edit, to: view) else { return }
                        // The undoable replace notifies the delegate, which is what carries
                        // the new text back. This line is the belt to that pair of braces:
                        // if a platform ever stops notifying, an edit that changed the view
                        // and not the model would be an edit Save could not see.
                        if binding.wrappedValue != view.text { binding.wrappedValue = view.text }
                    }
                }
                return
            }
            // ONLY when they differ — see the file comment on the jumping cursor.
            if view.text != text { view.text = text }
        }

        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate {
            @Binding var text: String
            let selection: Binding<NSRange>?
            var token = 0
            var editToken = 0

            init(text: Binding<String>, selection: Binding<NSRange>?) {
                _text = text
                self.selection = selection
            }

            func textViewDidChange(_ textView: UITextView) {
                text = textView.text
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard let selection else { return }
                let range = textView.selectedRange
                // ONLY when it moved. This fires on every keystroke as well as every tap,
                // and writing the same value back would invalidate the owner's body for
                // nothing on a screen whose keystroke budget is measured in milliseconds.
                if selection.wrappedValue != range { selection.wrappedValue = range }
            }
        }
    }
}

extension VaultPlainTextEditor {
    /// Apply one edit through the text view's own undoable replace, and leave the caret
    /// where the edit says.
    ///
    /// Static and handed a view so the seam can be exercised directly. It answers false
    /// for a range that is no longer inside the document, which is what a stale selection
    /// looks like after the text was replaced under it.
    @MainActor
    @discardableResult
    static func apply(_ edit: VaultTextEdit, to view: UITextView) -> Bool {
        let length = (view.text as NSString).length
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= length else { return false }
        guard let start = view.position(from: view.beginningOfDocument,
                                       offset: edit.range.location),
              let end = view.position(from: start, offset: edit.range.length),
              let range = view.textRange(from: start, to: end) else { return false }
        view.replace(range, withText: edit.replacement)
        let caret = min(edit.caret, (view.text as NSString).length)
        view.selectedRange = NSRange(location: caret, length: 0)
        return true
    }
}

#elseif os(macOS)

extension VaultPlainTextEditor {
    struct Representable: NSViewRepresentable {
        @Binding var text: String
        let resetToken: Int
        let selectedRange: Binding<NSRange>?
        let pendingEdit: VaultTextEdit?
        let editToken: Int

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, selection: selectedRange)
        }

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
            context.coordinator.editToken = editToken
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let view = scroll.documentView as? NSTextView else { return }
            if context.coordinator.token != resetToken {
                context.coordinator.token = resetToken
                context.coordinator.editToken = editToken
                view.string = text
                view.undoManager?.removeAllActions()
                return
            }
            if context.coordinator.editToken != editToken {
                context.coordinator.editToken = editToken
                if let edit = pendingEdit {
                    // One hop out of the update pass: see the file comment.
                    let binding = $text
                    Task { @MainActor in
                        guard VaultPlainTextEditor.apply(edit, to: view) else { return }
                        if binding.wrappedValue != view.string { binding.wrappedValue = view.string }
                    }
                }
                return
            }
            if view.string != text { view.string = text }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            @Binding var text: String
            let selection: Binding<NSRange>?
            var token = 0
            var editToken = 0

            init(text: Binding<String>, selection: Binding<NSRange>?) {
                _text = text
                self.selection = selection
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                text = view.string
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let selection, let view = notification.object as? NSTextView else { return }
                let range = view.selectedRange()
                // ONLY when it moved, for the reason the iOS half says.
                if selection.wrappedValue != range { selection.wrappedValue = range }
            }
        }
    }
}

extension VaultPlainTextEditor {
    /// Apply one edit through the text view's own undoable insertion, and leave the caret
    /// where the edit says.
    ///
    /// `insertText(_:replacementRange:)` is the text input path: it asks the delegate, it
    /// registers the undo, it posts the did-change notification the coordinator listens
    /// for. Replacing the text storage directly would do none of those three, which is
    /// how a programmatic edit ends up unsaveable and un-undoable at the same time.
    @MainActor
    @discardableResult
    static func apply(_ edit: VaultTextEdit, to view: NSTextView) -> Bool {
        let length = (view.string as NSString).length
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= length else { return false }
        view.insertText(edit.replacement, replacementRange: edit.range)
        let caret = min(edit.caret, (view.string as NSString).length)
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return true
    }
}

#endif
