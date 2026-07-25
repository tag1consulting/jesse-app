import XCTest
import AppKit
import SwiftUI
@testable import Jesse_Mac

/// The composer's text view, driven by real `NSEvent`s through the real `keyDown(with:)`: the
/// same path a key press takes in the running app. Where the previous suite could not see the
/// composer at all (a SwiftUI `TextField` plus `.onSubmit` has no seam), these exercise the code
/// that now decides: newline insertion at the caret, the send hand-off, and the binding round
/// trip that would otherwise throw the caret to the end of the message.
@MainActor
final class ComposerTextViewTests: XCTestCase {

    // MARK: - Fixtures

    /// Holds each test's host window alive for the duration of the test; released with the test
    /// case. They are never ordered on screen, so there is nothing to close, and closing them in
    /// `tearDown` is worse than not: `tearDown` is nonisolated even on a `@MainActor` test case,
    /// so reaching this main-actor state from it either fails the concurrency checker or needs an
    /// assumeIsolated dance for no benefit.
    private var windows: [NSWindow] = []

    /// A composer text view hosted in an off-screen window and made first responder, so the key
    /// path under test is the real one: a live input context and an undo manager from the
    /// responder chain, exactly as in the running app.
    private func textView(_ text: String = "") -> ComposerNSTextView {
        let frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        let view = ComposerNSTextView(frame: frame)
        view.font = ComposerNSTextView.composerFont
        view.isRichText = false
        view.allowsUndo = true

        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered,
                              defer: false)
        // A programmatically created window releases itself on close, which under ARC is an
        // over-release (the test still holds it) and segfaults the whole suite in the autorelease
        // pool pop. Own it here instead.
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        windows.append(window)

        view.string = text
        return view
    }

    private func keyEvent(_ modifiers: NSEvent.ModifierFlags = [],
                          keyCode: UInt16 = ComposerKeyCode.return,
                          characters: String = "\r") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    // MARK: - Newline insertion

    func testModifierReturnInsertsExactlyOneNewlineAtTheCaretAndDoesNotSend() {
        for modifier in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let view = textView("abcdef")
            view.setSelectedRange(NSRange(location: 3, length: 0))
            var sends = 0
            view.onSend = { sends += 1 }

            view.keyDown(with: keyEvent(modifier))

            XCTAssertEqual(view.string, "abc\ndef",
                           "one newline at the caret, the rest of the text untouched (\(modifier))")
            XCTAssertEqual(view.string.filter { $0 == "\n" }.count, 1, "exactly one newline")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0),
                           "the caret sits after the inserted newline")
            XCTAssertEqual(sends, 0, "a modifier plus Return never sends (\(modifier))")
        }
    }

    func testModifierReturnReplacesTheSelectionWithTheNewline() {
        let view = textView("abcXYZdef")
        view.setSelectedRange(NSRange(location: 3, length: 3))
        view.onSend = { XCTFail("must not send") }

        view.keyDown(with: keyEvent(.shift))

        XCTAssertEqual(view.string, "abc\ndef", "the selected run is replaced, as any typed key does")
    }

    func testRepeatedModifierReturnsBuildAMultilineDraft() {
        let view = textView()
        view.onSend = { XCTFail("must not send") }
        view.insertText("one", replacementRange: view.selectedRange())
        view.keyDown(with: keyEvent(.shift))
        view.insertText("two", replacementRange: view.selectedRange())
        view.keyDown(with: keyEvent(.control))
        view.insertText("three", replacementRange: view.selectedRange())

        XCTAssertEqual(view.string, "one\ntwo\nthree", "a three line message typed by hand")
    }

    func testModifierKeypadEnterInsertsANewlineEvenWithThePadFlagsSet() {
        let view = textView("ab")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.onSend = { XCTFail("must not send") }

        view.keyDown(with: keyEvent([.shift, .function, .numericPad],
                                    keyCode: ComposerKeyCode.keypadEnter, characters: "\u{3}"))

        XCTAssertEqual(view.string, "ab\n")
    }

    /// The newline goes in through the text input path, so it is one ordinary edit: undoable in a
    /// single step and redoable. (Manual item 9 checks the same thing with a real keyboard.)
    func testTheInsertedNewlineIsOneUndoStep() {
        let storage = Storage("ab")
        let coordinator = coordinator(storage)
        let view = textView("ab")
        // The coordinator supplies the composer's undo manager in the app, so use it here too.
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.onSend = { XCTFail("must not send") }
        let undo = view.undoManager

        view.keyDown(with: keyEvent(.shift))
        XCTAssertEqual(view.string, "ab\n")
        guard let undo else { return XCTFail("the hosted text view has no undo manager") }
        XCTAssertTrue(undo.canUndo, "the newline registered an undoable edit")

        undo.undo()
        XCTAssertEqual(view.string, "ab", "one undo removes the newline")
        undo.redo()
        XCTAssertEqual(view.string, "ab\n", "and redo puts it back")
    }

    // MARK: - Sending

    func testPlainReturnSendsAndLeavesTheTextAlone() {
        let view = textView("hello")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        var sends = 0
        view.onSend = { sends += 1 }

        view.keyDown(with: keyEvent())

        XCTAssertEqual(sends, 1, "plain Return sends")
        XCTAssertEqual(view.string, "hello", "and inserts nothing")
    }

    func testPlainKeypadEnterSends() {
        let view = textView("hello")
        var sends = 0
        view.onSend = { sends += 1 }

        view.keyDown(with: keyEvent([.function, .numericPad],
                                    keyCode: ComposerKeyCode.keypadEnter, characters: "\u{3}"))

        XCTAssertEqual(sends, 1, "keypad Enter sends like Return")
        XCTAssertEqual(view.string, "hello")
    }

    /// The composer does not decide whether a send is allowed: it calls the same `send()` the
    /// button calls, whose guard is the single source of truth. So an empty or whitespace-only
    /// draft reaches a send closure that does nothing, and no newline is inserted either.
    /// `MacComposerSendGateTests` pins the other half: that the guard really refuses.
    func testReturnOnAnEmptyOrWhitespaceOnlyDraftInsertsNothing() {
        for draft in ["", "   ", "\t ", "\n"] {
            let view = textView(draft)
            var sends = 0
            view.onSend = { sends += 1 }

            view.keyDown(with: keyEvent())

            XCTAssertEqual(view.string, draft, "Return must not edit the draft")
            XCTAssertEqual(sends, 1, "the decision is still send; the gate refuses it downstream")
        }
    }

    func testUnrelatedKeysAreNotIntercepted() {
        let view = textView()
        view.onSend = { XCTFail("a letter key must not send") }

        // Key code 0 is "a"; it goes to super and types.
        view.keyDown(with: keyEvent([], keyCode: 0, characters: "a"))

        XCTAssertEqual(view.string, "a", "ordinary typing still reaches the text system")
    }

    // MARK: - Binding round trip and caret stability

    private func coordinator(_ storage: Storage) -> ComposerTextView.Coordinator {
        ComposerTextView.Coordinator(text: Binding(get: { storage.value },
                                                   set: { storage.value = $0 }))
    }

    /// A stand-in for the SwiftUI `@State` behind the binding.
    final class Storage {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// The `NSViewRepresentable` caret defect: SwiftUI re-runs `updateNSView` after every
    /// keystroke, and a coordinator that writes the binding back into the text view
    /// unconditionally collapses the selection, so the caret jumps to the end and the user cannot
    /// edit the middle of their own message.
    func testPushingTheSameValueBackLeavesTheSelectionUntouched() {
        let storage = Storage("hello world")
        let coordinator = coordinator(storage)
        let view = textView("hello world")
        view.setSelectedRange(NSRange(location: 3, length: 2))

        coordinator.apply("hello world", to: view)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 2),
                       "an identical value must not move the caret or drop the selection")
        XCTAssertEqual(view.string, "hello world")
    }

    func testACaretInTheMiddleSurvivesManySwiftUIUpdates() {
        let storage = Storage("one\ntwo\nthree")
        let coordinator = coordinator(storage)
        let view = textView("one\ntwo\nthree")
        view.setSelectedRange(NSRange(location: 5, length: 0))

        for _ in 0..<10 { coordinator.apply(storage.value, to: view) }

        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testAnExternalChangeIsAppliedAndTheCaretStaysInBounds() {
        let storage = Storage("hello world")
        let coordinator = coordinator(storage)
        let view = textView("hello world")
        view.setSelectedRange(NSRange(location: 11, length: 0))

        // What a completed send does: clear the draft.
        coordinator.apply("", to: view)

        XCTAssertEqual(view.string, "")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0),
                       "the caret cannot dangle past the end of the new text")
    }

    /// Regression, and it was a CRASH, found by driving the real composer in a running app: typing
    /// registers an undoable edit, a completed send then replaces the text through `apply` (which
    /// is not an undoable edit), and Cmd+Z afterwards tried to undo the typing against text that
    /// no longer existed. `NSRangeException: Range {0, 5} out of bounds; string length 0` followed, taking
    /// the app down. `apply` now clears the composer's own undo stack at that boundary. This test
    /// dies with an uncatchable Objective-C exception if that regresses.
    func testUndoAfterTheDraftIsClearedDoesNotCrash() {
        let storage = Storage("")
        let coordinator = coordinator(storage)
        let view = textView()
        view.delegate = coordinator
        XCTAssertTrue(view.undoManager === coordinator.composerUndoManager,
                      "the composer owns its undo stack, it does not share the window's")

        view.insertText("hello", replacementRange: view.selectedRange())
        XCTAssertTrue(coordinator.composerUndoManager.canUndo, "typing is undoable")

        coordinator.apply("", to: view)   // what a completed send does

        XCTAssertFalse(coordinator.composerUndoManager.canUndo,
                       "nothing recorded before a wholesale replacement can be undone safely")
        coordinator.composerUndoManager.undo()
        XCTAssertEqual(view.string, "", "and the undo is a no-op rather than a crash")
    }

    func testAnEditInTheTextViewReachesTheBindingVerbatim() {
        let storage = Storage("")
        let coordinator = coordinator(storage)
        let view = textView("line one\nline two")

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

        XCTAssertEqual(storage.value, "line one\nline two",
                       "newlines reach the binding as newlines, not escapes")
    }

    // MARK: - Height

    func testHeightClampsBetweenTheLineFloorAndCeiling() {
        let inset: CGFloat = 4
        // Shorter than one line: still one line tall.
        XCTAssertEqual(ComposerHeight.clamped(textHeight: 3, lineHeight: 20, minLines: 1,
                                              maxLines: 8, verticalInset: inset), 24)
        // In between: exactly the text.
        XCTAssertEqual(ComposerHeight.clamped(textHeight: 60, lineHeight: 20, minLines: 1,
                                              maxLines: 8, verticalInset: inset), 64)
        // Taller than the ceiling: capped at eight lines (the text view scrolls past that).
        XCTAssertEqual(ComposerHeight.clamped(textHeight: 4000, lineHeight: 20, minLines: 1,
                                              maxLines: 8, verticalInset: inset), 164)
    }

    func testAnEmptyComposerIsStillOneLineTall() {
        let view = textView()
        XCTAssertEqual(view.measuredTextHeight(forWidth: 300), ComposerNSTextView.lineHeight,
                       "the composer must never collapse to nothing")
    }

    func testMeasuredHeightGrowsWithEachAddedLine() {
        let one = textView("one")
        let three = textView("one\ntwo\nthree")
        let trailing = textView("one\n")

        let oneHigh = one.measuredTextHeight(forWidth: 300)
        XCTAssertGreaterThan(three.measuredTextHeight(forWidth: 300), oneHigh,
                             "a three line draft is taller than a one line draft")
        XCTAssertGreaterThan(trailing.measuredTextHeight(forWidth: 300), oneHigh,
                             "a trailing newline opens a line, so the composer grows at once")
    }

    func testAVeryLongDraftStopsGrowingAtTheCeiling() {
        let view = textView(Array(repeating: "line", count: 200).joined(separator: "\n"))
        let height = ComposerHeight.clamped(textHeight: view.measuredTextHeight(forWidth: 300),
                                           lineHeight: ComposerNSTextView.lineHeight,
                                           minLines: 1, maxLines: 8, verticalInset: 0)
        XCTAssertEqual(height, ComposerNSTextView.lineHeight * 8,
                       "the composer must not grow without bound")
    }

    // MARK: - Placeholder

    /// `NSTextView` has no placeholder, so the composer draws its own. Counting painted pixels is
    /// crude but it is the only thing that actually proves something is on screen: the old
    /// `TextField` got its placeholder for free, and losing it silently would be easy.
    func testThePlaceholderIsDrawnWhenEmptyAndNotWhenThereIsText() {
        func paintedPixels(_ view: NSView) -> Int {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            var painted = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    painted += 1
                }
            }
            return painted
        }
        func view(placeholder: String, text: String) -> ComposerNSTextView {
            let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
            view.font = ComposerNSTextView.composerFont
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.placeholder = placeholder
            view.string = text
            return view
        }

        let blank = paintedPixels(view(placeholder: "", text: ""))
        let placeholderOnly = paintedPixels(view(placeholder: "Message Jesse…", text: ""))
        let realText = paintedPixels(view(placeholder: "Message Jesse…", text: "Message Jesse…"))
        let withText = paintedPixels(view(placeholder: "Message Jesse…", text: "x"))

        XCTAssertEqual(blank, 0, "an empty composer with no placeholder paints nothing")
        XCTAssertGreaterThan(placeholderOnly, 0, "the placeholder must actually be drawn")
        XCTAssertLessThan(abs(placeholderOnly - realText), realText / 2,
                          "and it is about as much ink as the same string typed for real")
        XCTAssertLessThan(withText, placeholderOnly,
                          "once there is text, the placeholder is gone")
    }

    // MARK: - Input method composition

    func testReturnDuringACompositionDoesNotSend() {
        let view = textView()
        var sends = 0
        view.onSend = { sends += 1 }
        // Marked (uncommitted) text, as an IME or a dead key leaves behind.
        view.setMarkedText("\u{3042}", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "precondition: a composition is live")

        view.keyDown(with: keyEvent())

        XCTAssertEqual(sends, 0, "Return commits the composition, it does not send a turn")
    }
}
