import XCTest
@testable import JesseVault

// THE CHARACTERS OF EVERY MARK, AND THE TWO REFUSALS.
//
// Every one of these is a line a person will read back in Obsidian tomorrow, so the
// assertions are on the exact string rather than on "contains a brace". The deletion form
// is spelled from its pieces in the source it tests, and written out here in a literal:
// this is where the two hyphens are allowed to appear.
final class VaultAnnotationMarkupTests: XCTestCase {

    private let line = "The arch is sound and the bricks are ordered."

    // MARK: - The five forms

    func testHighlightWithACommentIsTheTwoMarksAdjacent() {
        let mark = VaultAnnotationMarkup.highlight("the bricks are ordered",
                                                   comment: "Are they?")
        XCTAssertEqual(mark.text, "{==the bricks are ordered==}{>>Are they?<<}")
        XCTAssertEqual(mark.caret, mark.text.utf16.count,
                       "the caret lands past the closing brace, never inside the words")
    }

    func testAnEmptyCommentProducesABareHighlight() {
        for comment in ["", "   ", "\n"] {
            let mark = VaultAnnotationMarkup.highlight("the arch", comment: comment)
            XCTAssertEqual(mark.text, "{==the arch==}",
                           "an empty field must not produce an empty comment mark")
        }
    }

    func testCommentAlone() {
        let mark = VaultAnnotationMarkup.comment("Check the invoice")
        XCTAssertEqual(mark.text, "{>>Check the invoice<<}")
        XCTAssertEqual(mark.caret, 23)
    }

    func testSubstitutionCarriesBothHalves() {
        let mark = VaultAnnotationMarkup.substitution(old: "sound", new: "cracked")
        XCTAssertEqual(mark.text, "{~~sound~>cracked~~}")
        XCTAssertEqual(mark.caret, mark.text.utf16.count)
    }

    func testInsertion() {
        let mark = VaultAnnotationMarkup.insertion("and dry")
        XCTAssertEqual(mark.text, "{++and dry++}")
        XCTAssertEqual(mark.caret, mark.text.utf16.count)
    }

    func testDeletion() {
        let mark = VaultAnnotationMarkup.deletion("and the bricks are ordered")
        XCTAssertEqual(mark.text, "{--and the bricks are ordered--}")
        XCTAssertEqual(mark.caret, mark.text.utf16.count)
    }

    /// A pasted paragraph inside a mark would break the reader's one line rule from the
    /// inside, where no selection check can see it.
    func testFieldTextIsFlattenedToOneLine() {
        XCTAssertEqual(VaultAnnotationMarkup.comment("first\nsecond").text,
                       "{>>first second<<}")
        XCTAssertEqual(VaultAnnotationMarkup.insertion("a\n\n  b  ").text, "{++a b++}")
    }

    // MARK: - The refusals

    func testASelectionCrossingALineIsRefusedForEveryForm() {
        let note = "First line\nSecond line\n"
        let crossing = NSRange(location: 6, length: 10)
        XCTAssertEqual(VaultAnnotationMarkup.refusal(forSelection: crossing, in: note),
                       VaultAnnotationMarkup.multiLineCaption)
        for form in VaultAnnotationForm.allCases {
            XCTAssertEqual(VaultAnnotationMarkup.refusal(forSelection: crossing, in: note,
                                                         form: form),
                           VaultAnnotationMarkup.multiLineCaption,
                           "\(form.label) must refuse a selection that crosses a line")
            XCTAssertNil(VaultAnnotationMarkup.edit(form, selection: crossing, in: note,
                                                    field: "words"),
                         "\(form.label) must not clip a multi-line selection")
        }
    }

    func testTheThreeFormsThatNeedWordsRefuseAnEmptySelection() {
        let caret = NSRange(location: 4, length: 0)
        for form in VaultAnnotationForm.allCases where form.needsSelection {
            XCTAssertEqual(VaultAnnotationMarkup.refusal(forSelection: caret, in: line,
                                                         form: form),
                           VaultAnnotationMarkup.noSelectionCaption)
            XCTAssertNil(VaultAnnotationMarkup.edit(form, selection: caret, in: line,
                                                    field: "words"))
        }
        for form in VaultAnnotationForm.allCases where !form.needsSelection {
            XCTAssertNil(VaultAnnotationMarkup.refusal(forSelection: caret, in: line,
                                                       form: form),
                         "\(form.label) acts at a point and needs no selection")
        }
    }

    func testAStaleRangeIsRefusedRatherThanCrashing() {
        let past = NSRange(location: line.utf16.count + 5, length: 3)
        XCTAssertEqual(VaultAnnotationMarkup.refusal(forSelection: past, in: line),
                       VaultAnnotationMarkup.outOfBoundsCaption)
        XCTAssertNil(VaultAnnotationMarkup.edit(.highlight, selection: past, in: line,
                                                field: ""))
    }

    func testTheBarCaptionNamesTheEmptySelectionAndThenTheLineBreak() {
        XCTAssertNil(VaultAnnotationMarkup.caption(forSelection: NSRange(location: 4, length: 5),
                                                   in: line))
        XCTAssertEqual(VaultAnnotationMarkup.caption(forSelection: NSRange(location: 4, length: 0),
                                                     in: line),
                       VaultAnnotationMarkup.noSelectionCaption)
        XCTAssertEqual(VaultAnnotationMarkup.caption(forSelection: NSRange(location: 6, length: 10),
                                                     in: "First line\nSecond line\n"),
                       VaultAnnotationMarkup.multiLineCaption)
    }

    // MARK: - Edits

    func testAReplaceEditWrapsTheSelectionAndLeavesTheCaretAfterIt() {
        // "sound"
        let selection = NSRange(location: 12, length: 5)
        XCTAssertEqual((line as NSString).substring(with: selection), "sound")
        let edit = try? XCTUnwrap(VaultAnnotationMarkup.edit(.substitution, selection: selection,
                                                            in: line, field: "cracked"))
        guard let edit else { return XCTFail("expected an edit") }
        XCTAssertEqual(edit.range, selection)
        XCTAssertEqual(edit.replacement, "{~~sound~>cracked~~}")
        XCTAssertEqual(edit.applied(to: line),
                       "The arch is {~~sound~>cracked~~} and the bricks are ordered.")
        XCTAssertEqual(edit.caret, selection.location + edit.replacement.utf16.count)
    }

    func testADeleteEditNeedsNoFieldAtAll() {
        let selection = NSRange(location: 12, length: 5)
        let edit = VaultAnnotationMarkup.edit(.deletion, selection: selection, in: line)
        XCTAssertEqual(edit?.applied(to: line),
                       "The arch is {--sound--} and the bricks are ordered.")
    }

    func testAnEmptyFieldRefusesEveryFormButTheHighlight() {
        let selection = NSRange(location: 12, length: 5)
        XCTAssertNotNil(VaultAnnotationMarkup.edit(.highlight, selection: selection, in: line,
                                                   field: "  "),
                        "a bare highlight is a mark")
        XCTAssertNil(VaultAnnotationMarkup.edit(.substitution, selection: selection, in: line,
                                                field: " "))
        XCTAssertNil(VaultAnnotationMarkup.edit(.comment, selection: selection, in: line,
                                                field: ""))
        XCTAssertNil(VaultAnnotationMarkup.edit(.insertion, selection: selection, in: line,
                                                field: "\n"))
    }

    /// A comment lands after the words rather than inside them, so the pair reads the way
    /// the renderer draws it.
    func testACommentWithWordsSelectedLandsAtTheEndOfThem() {
        let selection = NSRange(location: 12, length: 5)
        let edit = VaultAnnotationMarkup.edit(.comment, selection: selection, in: line,
                                              field: "Is it?")
        XCTAssertEqual(edit?.range, NSRange(location: 17, length: 0))
        XCTAssertEqual(edit?.applied(to: line),
                       "The arch is sound{>>Is it?<<} and the bricks are ordered.")
    }

    func testAnInsertionAtTheCaretReplacesNothing() {
        let caret = NSRange(location: 11, length: 0)
        let edit = VaultAnnotationMarkup.edit(.insertion, selection: caret, in: line,
                                              field: "very")
        XCTAssertEqual(edit?.range, caret)
        XCTAssertEqual(edit?.applied(to: line),
                       "The arch is{++very++} sound and the bricks are ordered.")
    }

    func testReplaceIsTheOnlyFormThatPrefillsItsField() {
        let selection = NSRange(location: 12, length: 5)
        XCTAssertEqual(VaultAnnotationMarkup.prefill(.substitution, selection: selection,
                                                     in: line), "sound")
        for form in VaultAnnotationForm.allCases where form != .substitution {
            XCTAssertEqual(VaultAnnotationMarkup.prefill(form, selection: selection, in: line), "")
        }
    }

    /// The marks are UTF-16 ranges because that is what both text views count in, and an
    /// accented vowel is where a character count and a code unit count part company.
    func testARangeOverNonASCIITextMarksTheWordsThatWereSelected() {
        let italian = "Il forno è però freddo."
        let selection = NSRange(location: 12, length: 3)
        XCTAssertEqual((italian as NSString).substring(with: selection), "erò")
        let edit = VaultAnnotationMarkup.edit(.highlight, selection: selection, in: italian)
        XCTAssertEqual(edit?.applied(to: italian), "Il forno è p{==erò==} freddo.")
    }

    // MARK: - Counting

    func testTheCountIsEveryMarkButAReply() {
        let texts = ["{==one==}{>>why?<<}",
                     "{~~old~>new~~} and {++added++} and {--gone--}",
                     "{>>Jesse fixed it<<}"]
        // highlight, comment, substitution, insertion, deletion: five. The reply is not one.
        XCTAssertEqual(VaultAnnotationMarkup.count(in: texts), 5)
    }

    func testTextWithNoBraceCostsNothingAndCountsNothing() {
        XCTAssertEqual(VaultAnnotationMarkup.count(in: ["ordinary ==highlight== and a #tag"]), 0)
    }

    func testTheCountCaptionIsSingularForOne() {
        XCTAssertEqual(VaultAnnotationMarkup.countCaption(1), "1 annotation")
        XCTAssertEqual(VaultAnnotationMarkup.countCaption(0), "0 annotations")
        XCTAssertEqual(VaultAnnotationMarkup.countCaption(3), "3 annotations")
    }
}
