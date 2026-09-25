import Foundation
import JesseMarkdown

// THE FIVE MARKS, AS TEXT, WITH NOBODY'S CURSOR IN THE WAY.
//
// Reading a marked up note has worked since the renderer learned the five CriticMarkup
// forms. MAKING one meant typing braces by hand on a phone keyboard, which is the kind of
// thing a person does twice and then stops doing: `{~~`, the old words, `~>`, the new
// words, `~~}`, and one mistyped tilde turns a rewrite into a paragraph of punctuation.
//
// So the characters are built here, and ONLY here. Every function is pure: selection and
// field text in, replacement text and caret out. That is what makes the editor's bar five
// buttons over a tested function rather than five string literals scattered through a
// view, and it is what lets the awkward cases (an empty comment, a selection that crosses
// a line, a selection at the very end of the file) be stated as assertions instead of
// discovered on a phone.
//
// TWO RULES THE BUILDER ENFORCES, both of them the reader's rules read backwards:
//
//   ONE LINE. A mark opens and closes on one line, because the renderer matches a closer
//   on the line it opened on and a mark that spanned three lines would be a mark the
//   reader silently swallows. A selection crossing a line break is therefore REFUSED,
//   never clipped to the first line: clipping would mark words the person did not choose.
//
//   THE CARET LANDS AFTER THE MARK. Every form returns a caret past its closing brace, so
//   the next keystroke continues the sentence rather than landing inside the words that
//   were just marked, where it would be swallowed into the mark's own text.

/// One edit to a text view's contents: what to replace, with what, and where to leave the
/// caret.
///
/// UTF-16 throughout, because it is what both platforms' text views count in. A
/// `String.Index` would have to be converted at every boundary, and the conversion is
/// exactly where an emoji or an accented Italian vowel turns an off-by-one into a mark
/// that opens in the middle of a character.
public struct VaultTextEdit: Equatable, Sendable {
    /// The UTF-16 range this edit replaces. An empty range is an insertion at its location.
    public let range: NSRange
    public let replacement: String
    /// Where the caret goes afterwards, as an absolute UTF-16 offset.
    public let caret: Int

    public init(range: NSRange, replacement: String, caret: Int) {
        self.range = range
        self.replacement = replacement
        self.caret = caret
    }

    /// This edit applied to a string.
    ///
    /// The text views apply their own version of this through their undo machinery, so
    /// this one exists for the pure half: a model asserting what a mark does to a note
    /// without a view, and a caller that holds text rather than a text view. Out of bounds
    /// is the identity, never a crash.
    public func applied(to text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return text }
        return ns.replacingCharacters(in: range, with: replacement)
    }
}

/// One mark's characters, and where the caret goes relative to their start.
public struct VaultMarkup: Equatable, Sendable {
    public let text: String
    /// Offset from the start of `text`. Always its end: see the file comment.
    public let caret: Int

    public init(text: String) {
        self.text = text
        self.caret = text.utf16.count
    }
}

/// Which mark a button makes.
public enum VaultAnnotationForm: String, CaseIterable, Identifiable, Sendable {
    case highlight
    case substitution
    case deletion
    case insertion
    case comment

    public var id: String { rawValue }

    /// The word on the button. "Replace" rather than "Substitute" and "Delete" rather than
    /// "Deletion": the bar is read by the person marking the note, not by whoever named
    /// the grammar.
    public var label: String {
        switch self {
        case .highlight: return "Highlight"
        case .substitution: return "Replace"
        case .deletion: return "Delete"
        case .insertion: return "Insert"
        case .comment: return "Comment"
        }
    }

    public var symbol: String {
        switch self {
        case .highlight: return "highlighter"
        case .substitution: return "arrow.triangle.2.circlepath"
        case .deletion: return "strikethrough"
        case .insertion: return "text.insert"
        case .comment: return "text.bubble"
        }
    }

    /// Whether the mark is about words that are already there.
    ///
    /// Three of the five are, and those three are the ones a bar disables with nothing
    /// selected. A comment and an insertion happen AT a point, so they are always
    /// available, and with words selected they land just after them.
    public var needsSelection: Bool {
        switch self {
        case .highlight, .substitution, .deletion: return true
        case .insertion, .comment: return false
        }
    }

    /// Whether the form asks for words of its own before it can be applied.
    ///
    /// Delete does not: the selection is the whole of it, so it applies on the tap.
    public var asksForText: Bool { self != .deletion }

    /// Whether an empty field still produces a mark.
    ///
    /// Only a highlight, and that is the point of the empty case: highlighting a sentence
    /// with nothing to say about it yet is a real thing to want, and it produces a bare
    /// `{==sentence==}` rather than a comment containing nothing.
    public var allowsEmptyText: Bool { self == .highlight }

    /// What the sheet asks for.
    public var fieldPrompt: String {
        switch self {
        case .highlight: return "Add a comment, or leave it empty"
        case .substitution: return "What it should say instead"
        case .insertion: return "The words to add"
        case .comment: return "What you want to say"
        case .deletion: return ""
        }
    }

    /// The sheet's own title.
    public var sheetTitle: String {
        switch self {
        case .highlight: return "Highlight"
        case .substitution: return "Replace the selection"
        case .insertion: return "Insert words"
        case .comment: return "Leave a comment"
        case .deletion: return "Delete the selection"
        }
    }
}

/// The five forms as text, and the two refusals.
public enum VaultAnnotationMarkup {

    /// `{==words==}`, with `{>>comment<<}` right behind it when there is one.
    ///
    /// The comment follows the highlight immediately, with nothing between them, because
    /// that adjacency is what makes the pair read as one mark: the renderer draws the
    /// words on yellow and the comment behind its own marker, and a space in between would
    /// put a gap in the middle of a sentence nobody typed.
    public static func highlight(_ words: String, comment: String = "") -> VaultMarkup {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VaultMarkup(text: "{==" + words + "==}") }
        return VaultMarkup(text: "{==" + words + "==}{>>" + oneLine(trimmed) + "<<}")
    }

    /// `{>>a note<<}` on its own.
    public static func comment(_ text: String) -> VaultMarkup {
        VaultMarkup(text: "{>>" + oneLine(text) + "<<}")
    }

    /// `{~~old~>new~~}`, both halves carried so the reader can strike one and set the other.
    public static func substitution(old: String, new: String) -> VaultMarkup {
        VaultMarkup(text: "{~~" + old + "~>" + oneLine(new) + "~~}")
    }

    /// `{++words++}`.
    public static func insertion(_ text: String) -> VaultMarkup {
        VaultMarkup(text: "{++" + oneLine(text) + "++}")
    }

    /// The deletion mark: an opening brace, two hyphens, the words, two hyphens, a closing
    /// brace. Spelled from its pieces rather than written out, which is also how the
    /// renderer's own comment spells it.
    public static func deletion(_ words: String) -> VaultMarkup {
        let fence = String(repeating: "-", count: 2)
        return VaultMarkup(text: "{" + fence + words + fence + "}")
    }

    /// Why this selection cannot carry a mark, or nil.
    ///
    /// `form` nil asks the general question ("is this selection usable at all"), which is
    /// what a bar shows above five buttons; a form asks whether that one button can act.
    public static func refusal(forSelection selection: NSRange, in text: String,
                               form: VaultAnnotationForm? = nil) -> String? {
        guard let selected = selected(selection, in: text) else { return outOfBoundsCaption }
        if selected.contains("\n") { return multiLineCaption }
        if let form, form.needsSelection, selection.length == 0 { return noSelectionCaption }
        return nil
    }

    /// The caption a bar shows for the selection it has, or nil when the selection is a
    /// usable one.
    ///
    /// The line break case first, because it is the one that refuses every button; an
    /// empty selection only refuses three of them and says so in gentler words.
    public static func caption(forSelection selection: NSRange, in text: String) -> String? {
        if let refused = refusal(forSelection: selection, in: text) { return refused }
        if selection.length == 0 { return noSelectionCaption }
        return nil
    }

    public static let multiLineCaption = "Select within one line to annotate."
    public static let noSelectionCaption = "Select the words to mark first."
    static let outOfBoundsCaption = "That selection is no longer in this note."

    /// The edit one button makes, or nil when this selection refuses this form.
    ///
    /// The ONE place a selection, a field and a form become an edit. The bar calls it, the
    /// tests call it, and nothing else knows how a mark is spelled.
    public static func edit(_ form: VaultAnnotationForm, selection: NSRange, in text: String,
                            field: String = "") -> VaultTextEdit? {
        guard refusal(forSelection: selection, in: text, form: form) == nil else { return nil }
        guard let selected = selected(selection, in: text) else { return nil }
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if form.asksForText, trimmed.isEmpty, !form.allowsEmptyText { return nil }

        let markup: VaultMarkup
        let range: NSRange
        switch form {
        case .highlight:
            markup = highlight(selected, comment: trimmed)
            range = selection
        case .substitution:
            markup = substitution(old: selected, new: trimmed)
            range = selection
        case .deletion:
            markup = deletion(selected)
            range = selection
        case .insertion:
            markup = insertion(trimmed)
            // AT A POINT, and the point is the END of whatever is selected: with nothing
            // selected that is the caret, and with words selected it is just after them,
            // which leaves the person's own words alone rather than replacing them.
            range = NSRange(location: NSMaxRange(selection), length: 0)
        case .comment:
            markup = comment(trimmed)
            range = NSRange(location: NSMaxRange(selection), length: 0)
        }
        return VaultTextEdit(range: range, replacement: markup.text,
                             caret: range.location + markup.caret)
    }

    /// What a Replace sheet opens with: the words being replaced, so the common edit (fix
    /// two words of a sentence) starts from the sentence rather than from nothing.
    public static func prefill(_ form: VaultAnnotationForm, selection: NSRange,
                               in text: String) -> String {
        guard form == .substitution else { return "" }
        return selected(selection, in: text) ?? ""
    }

    // MARK: - Counting

    /// How many marks a note carries, counting a highlight, a comment, a rewrite, an
    /// insertion and a deletion, and NOT counting a comment that is already an answer.
    ///
    /// A reply (`{>>Jesse …<<}`) is excluded because the number is there to say how much
    /// is waiting to be looked at. A note that has been gone through end to end would
    /// otherwise read as having twice as much outstanding as it started with.
    ///
    /// The SAME scanner the renderer uses, so the count and the page can never disagree,
    /// behind a byte test for a brace: the overwhelming majority of this vault's lines
    /// have no mark in them, and a note with none costs one pass over its bytes.
    public static func count(in texts: [String]) -> Int {
        var total = 0
        for text in texts where text.utf8.contains(UInt8(ascii: "{")) {
            for span in MarkdownInline.scan(text) {
                switch span {
                case .criticHighlight, .criticSubstitution, .criticInsertion, .criticDeletion:
                    total += 1
                case .criticComment(let body):
                    if !VaultNoteRenderer.isReply(body) { total += 1 }
                default:
                    break
                }
            }
        }
        return total
    }

    /// "3 annotations", and the singular that stops it reading like a machine.
    public static func countCaption(_ count: Int) -> String {
        count == 1 ? "1 annotation" : "\(count) annotations"
    }

    // MARK: - Helpers

    /// The selected substring, or nil when the range is not inside this text.
    ///
    /// A range CAN go stale: it came from a text view, and between the selection changing
    /// and a button being pressed the model's text may have been replaced under it (a
    /// Reload, a restored stash). Nil rather than a crash, and the caller refuses.
    static func selected(_ selection: NSRange, in text: String) -> String? {
        let ns = text as NSString
        guard selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= ns.length else { return nil }
        return ns.substring(with: selection)
    }

    /// One line, whatever was typed into the field.
    ///
    /// A field is one line on iOS and can be pasted into on both platforms, and a pasted
    /// paragraph inside a mark is the one thing that would break the reader's one line
    /// rule from the inside. The newlines become spaces rather than being refused: the
    /// words are what the person meant, and the line break is a side effect of where they
    /// copied them from.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
