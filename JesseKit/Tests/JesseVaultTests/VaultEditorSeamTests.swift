import XCTest
import SwiftUI
@testable import JesseVault
#if os(macOS)
import AppKit
#endif

// THE SEAM ITSELF, AGAINST A REAL TEXT VIEW.
//
// `VaultAnnotationMarkupTests` proves the characters; this proves the delivery, which is a
// different claim and the one that was genuinely uncertain. A programmatic edit has three
// jobs and it is possible to do the first while silently failing the other two: change what
// is on screen, tell the delegate (which is what carries the new text into the model, and
// so into Save), and register an undo (which is what a person who marked the wrong sentence
// presses). Assigning `string` does the first only, which is why the editor does not.
//
// macOS only, for the reason the latency test is: an `NSTextView` needs no host, and the
// `UITextView` path needs a simulator. The iOS half of the same seam is verified by running
// the app.
final class VaultEditorSeamTests: XCTestCase {

    #if os(macOS)

    @MainActor
    private func makeView(_ text: String) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false
        view.allowsUndo = true
        view.string = text
        return view
    }

    @MainActor
    func testAnEditGoesInThroughTheTextViewAndComesBackThroughTheDelegate() {
        let note = "The arch is sound."
        var model = note
        let view = makeView(note)
        // The editor's own coordinator, which is the object under test as much as the apply
        // is: it is what turns a did-change notification into a write to the binding.
        let coordinator = VaultPlainTextEditor.Representable.Coordinator(
            text: Binding(get: { model }, set: { model = $0 }), selection: nil)
        view.delegate = coordinator

        let selection = NSRange(location: 12, length: 5)
        let edit = VaultAnnotationMarkup.edit(.substitution, selection: selection,
                                              in: note, field: "cracked")
        guard let edit else { return XCTFail("expected an edit") }

        XCTAssertTrue(VaultPlainTextEditor.apply(edit, to: view))

        XCTAssertEqual(view.string, "The arch is {~~sound~>cracked~~}.")
        XCTAssertEqual(model, view.string,
                       "the delegate must carry the marked text into the binding, or Save cannot see it")
        XCTAssertEqual(view.selectedRange(),
                       NSRange(location: edit.caret, length: 0),
                       "the caret lands after the mark, never inside it")
    }

    @MainActor
    func testTheSelectionReachesTheBinding() {
        let note = "The arch is sound."
        var model = note
        var selection = NSRange(location: 0, length: 0)
        let view = makeView(note)
        let coordinator = VaultPlainTextEditor.Representable.Coordinator(
            text: Binding(get: { model }, set: { model = $0 }),
            selection: Binding(get: { selection }, set: { selection = $0 }))
        view.delegate = coordinator

        view.setSelectedRange(NSRange(location: 12, length: 5))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: view))

        XCTAssertEqual(selection, NSRange(location: 12, length: 5))
    }

    /// A range that is no longer inside the document is refused rather than thrown at
    /// AppKit, which is where an `NSRangeException` would come from.
    @MainActor
    func testAStaleRangeIsRefused() {
        let view = makeView("short")
        let edit = VaultTextEdit(range: NSRange(location: 40, length: 3),
                                 replacement: "x", caret: 41)
        XCTAssertFalse(VaultPlainTextEditor.apply(edit, to: view))
        XCTAssertEqual(view.string, "short")
    }

    /// The mark is one undo, because it went in through the text input path rather than by
    /// assignment. A person who marked the wrong sentence gets it back.
    @MainActor
    func testTheEditIsUndoable() throws {
        let note = "The arch is sound."
        let view = makeView(note)
        let undo = UndoManager()
        // A standalone text view has no window to inherit an undo manager from, so the
        // delegate supplies one. This is the same hook AppKit uses in the app.
        let owner = UndoProvider(undo: undo)
        view.delegate = owner

        let edit = VaultAnnotationMarkup.edit(.deletion, selection: NSRange(location: 12, length: 5),
                                              in: note)
        XCTAssertTrue(VaultPlainTextEditor.apply(try XCTUnwrap(edit), to: view))
        XCTAssertEqual(view.string, "The arch is {--sound--}.")

        XCTAssertTrue(undo.canUndo, "an edit nobody can undo is an edit nobody can take back")
        undo.undo()
        XCTAssertEqual(view.string, note)
    }

    /// Supplies the undo manager a windowless text view has nowhere else to get.
    private final class UndoProvider: NSObject, NSTextViewDelegate {
        let undo: UndoManager
        init(undo: UndoManager) { self.undo = undo }
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    #endif
}
