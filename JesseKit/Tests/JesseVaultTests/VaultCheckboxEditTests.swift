import XCTest
@testable import JesseVault

// ONE LINE CHANGES AND NOTHING ELSE DOES.
//
// Almost every assertion here is about what the function LEFT ALONE. That is the feature:
// a tick that also normalised the indentation, or straightened a quote, or dropped the
// trailing spaces somebody aligned a column with, would show up on the Studio as a
// whole-file diff for a one-character change.
final class VaultCheckboxEditTests: XCTestCase {

    // MARK: - The grammar

    func testEveryDepthAndEveryMarker() {
        let cases: [(String, String)] = [
            ("- [ ] top level",            "- [x] top level"),
            ("  - [ ] two spaces",         "  - [x] two spaces"),
            ("    - [ ] four spaces",      "    - [x] four spaces"),
            ("\t- [ ] one tab",            "\t- [x] one tab"),
            ("\t\t- [ ] two tabs",         "\t\t- [x] two tabs"),
            ("\t\t\t- [ ] three tabs",     "\t\t\t- [x] three tabs"),
            ("* [ ] a star",               "* [x] a star"),
            ("+ [ ] a plus",               "+ [x] a plus"),
            ("1. [ ] numbered",            "1. [x] numbered"),
            ("12) [ ] numbered, paren",    "12) [x] numbered, paren"),
        ]
        for (before, after) in cases {
            XCTAssertEqual(VaultCheckboxEdit.setting(line: before, checked: true), after,
                           "ticking “\(before)”")
            XCTAssertEqual(VaultCheckboxEdit.setting(line: after, checked: false), before,
                           "unticking “\(after)”")
        }
    }

    /// `[X]` is what some editors write, and a tick that did not recognise it would report
    /// the item as undone and then tick an already-ticked box.
    func testCapitalXIsRecognisedAndNormalisedOnlyWhenWritten() {
        XCTAssertEqual(VaultCheckboxEdit.box(in: "- [X] done")?.checked, true)
        // Untick it: the X becomes a space, the rest of the line is untouched.
        XCTAssertEqual(VaultCheckboxEdit.setting(line: "- [X] done", checked: false),
                       "- [ ] done")
        // Ticking an already-ticked `[X]` writes a lowercase `x`, which is the one
        // character this function is allowed to change.
        XCTAssertEqual(VaultCheckboxEdit.setting(line: "- [X] done", checked: true),
                       "- [x] done")
    }

    func testNonCheckboxLinesAreNil() {
        for line in [
            "",
            "# A heading",
            "- an ordinary bullet",
            "-[x] no space after the marker",
            "- [] no room for a mark",
            "- [-] a cancelled task this function does not understand",
            "- [/] an in-progress task this function does not understand",
            "  plain indented text",
            "> [!note] a callout",
            "| [ ] | a table cell |",
            "[ ] no list marker at all",
        ] {
            XCTAssertNil(VaultCheckboxEdit.setting(line: line, checked: true),
                         "“\(line)” must not be treated as a checkbox")
        }
    }

    /// The reason the grammar insists on a space: `*emphasis*` starts with a list marker
    /// character and must never be mistaken for one.
    func testEmphasisIsNotAListMarker() {
        XCTAssertNil(VaultCheckboxEdit.setting(line: "*[ ]* not a task", checked: true))
    }

    // MARK: - Everything else survives

    func testTheRestOfTheLineIsPreservedByteForByte() {
        let line = "\t\t- [ ]   two   spaces   everywhere, a [[Wiki Link]] and trailing   "
        let ticked = VaultCheckboxEdit.setting(line: line, checked: true)
        XCTAssertEqual(ticked, "\t\t- [x]   two   spaces   everywhere, a [[Wiki Link]] and trailing   ")
        // And exactly one character differs.
        XCTAssertEqual(zip(line, ticked ?? "").filter { $0 != $1 }.count, 1)
    }

    func testTheRestOfTheFileIsPreservedByteForByte() {
        let note = """
            ---
            title: Kiln
            ---

            # Firing

            - [ ] order the anchors
            \t- [ ] and the castable
            - [x] measure the arch

            ```
            - [ ] this one is inside a fence
            ```

            Trailing paragraph.
            """
        let edited = VaultCheckboxEdit.setting(note, line: 7, checked: true)
        XCTAssertEqual(edited, note.replacingOccurrences(of: "- [ ] order the anchors",
                                                         with: "- [x] order the anchors"))
        // Line 12 IS a checkbox line as far as this pure function is concerned — it has no
        // idea what a fence is, and it must not: the reader is what decides which lines
        // are offered as controls, and it never offers one inside a code block.
        XCTAssertNotNil(VaultCheckboxEdit.setting(note, line: 12, checked: true))
    }

    func testABlankLineIsCountedSoLineNumbersAreTheFilesOwn() {
        let note = "a\n\n\n- [ ] four\n"
        XCTAssertEqual(VaultCheckboxEdit.setting(note, line: 4, checked: true),
                       "a\n\n\n- [x] four\n")
        XCTAssertNil(VaultCheckboxEdit.setting(note, line: 2, checked: true))
    }

    func testOutOfRangeLinesAreNil() {
        let note = "- [ ] one\n"
        XCTAssertNil(VaultCheckboxEdit.setting(note, line: 0, checked: true))
        XCTAssertNil(VaultCheckboxEdit.setting(note, line: 99, checked: true))
        XCTAssertNil(VaultCheckboxEdit.setting(note, line: -3, checked: true))
    }

    /// Two identical task lines is an ordinary thing for a list to contain, and the reason
    /// the function takes a line number rather than matching on text.
    func testTwoIdenticalLinesTickIndependently() {
        let note = "- [ ] call Marco\n- [ ] call Marco\n"
        XCTAssertEqual(VaultCheckboxEdit.setting(note, line: 2, checked: true),
                       "- [ ] call Marco\n- [x] call Marco\n")
    }

    func testCRLFLinesKeepTheirCarriageReturn() {
        let note = "# A\r\n- [ ] b\r\n"
        let edited = VaultCheckboxEdit.setting(note, line: 2, checked: true)
        XCTAssertEqual(edited, "# A\r\n- [x] b\r\n")
    }

    // MARK: - State

    func testStateReportsWhatIsThere() {
        let note = "- [ ] one\n- [x] two\nnot a task\n"
        XCTAssertEqual(VaultCheckboxEdit.state(of: note, line: 1), false)
        XCTAssertEqual(VaultCheckboxEdit.state(of: note, line: 2), true)
        XCTAssertNil(VaultCheckboxEdit.state(of: note, line: 3))
        XCTAssertNil(VaultCheckboxEdit.state(of: note, line: 4))
    }

    // MARK: - The archive footer, which is the case that matters

    /// A `- [ ]` inside a fence must never become a control. It is not prevented at tap
    /// time: the PARSER never makes a `.checkbox` block out of a fence's contents, so
    /// there is no control there to tap. This asserts that, because "the reader does not
    /// offer it" is the whole mechanism.
    func testACheckboxInsideACodeBlockIsNotACheckboxBlock() {
        let note = """
            # A note

            - [ ] a real task

            ```
            - [ ] not a task, it is example markdown
            ```
            """
        let document = VaultNoteDocument.parse(path: "N.md", text: note)
        let boxes = document.blocks.filter {
            if case .checkbox = $0.kind { return true }
            return false
        }
        XCTAssertEqual(boxes.count, 1, "only the task outside the fence is a checkbox")
        XCTAssertEqual(boxes.first?.text, "a real task")
        XCTAssertTrue(document.blocks.contains {
            if case .code = $0.kind { return $0.text.contains("- [ ] not a task") }
            return false
        })
    }

    func testTheArchiveFooterIsTickable() {
        let draft = """
            # A draft

            Some body text.

            ---

            - [ ] Archive only
            - [ ] Archive and extract to the knowledge base
            """
        let ticked = try? XCTUnwrap(VaultCheckboxEdit.setting(draft, line: 7, checked: true))
        XCTAssertEqual(ticked?.contains("- [x] Archive only"), true)
        XCTAssertEqual(ticked?.contains("- [ ] Archive and extract"), true)
    }
}

// THE FILE'S SHAPE, which is the other half of "nothing else changed".
final class VaultTextShapeTests: XCTestCase {

    func testLineEndingIsDecidedByTheFirstBreak() {
        XCTAssertEqual(VaultTextShape.of("a\nb\n").lineEnding, .lf)
        XCTAssertEqual(VaultTextShape.of("a\r\nb\r\n").lineEnding, .crlf)
        // No break at all: LF, because that is what the next line added will be.
        XCTAssertEqual(VaultTextShape.of("one line, no break").lineEnding, .lf)
        XCTAssertEqual(VaultTextShape.of("").lineEnding, .lf)
        // Mixed: the FIRST break wins rather than a majority vote.
        XCTAssertEqual(VaultTextShape.of("a\nb\r\nc\r\n").lineEnding, .lf)
        XCTAssertEqual(VaultTextShape.of("a\r\nb\nc\n").lineEnding, .crlf)
    }

    /// Swift's `Character` is a grapheme cluster and `"\r\n"` is ONE of them, so
    /// `hasSuffix("\n")` is false for a CRLF file. This asserts the byte-wise answer.
    func testTrailingNewlineIsSeenThroughACRLF() {
        XCTAssertTrue(VaultTextShape.of("a\r\n").endsWithNewline)
        XCTAssertTrue(VaultTextShape.of("a\n").endsWithNewline)
        XCTAssertFalse(VaultTextShape.of("a").endsWithNewline)
        XCTAssertFalse(VaultTextShape.of("a\r").endsWithNewline)
    }

    func testNormalisationDropsOnlyTheCRThatPrecedesAnLF() {
        XCTAssertEqual(VaultTextShape.normalised("a\r\nb\r\n"), "a\nb\n")
        XCTAssertEqual(VaultTextShape.normalised("a\nb\n"), "a\nb\n")
        // A lone CR is data, not a line ending, and is left where it is.
        XCTAssertEqual(VaultTextShape.normalised("a\rb"), "a\rb")
        // The pathological case a string replace turns into a CRLF file.
        XCTAssertEqual(VaultTextShape.normalised("a\r\r\n"), "a\r\n")
    }

    func testAppliedGivesTheShapeBack() {
        let crlf = VaultTextShape(lineEnding: .crlf, endsWithNewline: true)
        XCTAssertEqual(crlf.applied(to: "a\nb"), "a\r\nb\r\n")
        XCTAssertEqual(crlf.applied(to: "a\r\nb\r\n"), "a\r\nb\r\n", "must be idempotent")

        let lf = VaultTextShape(lineEnding: .lf, endsWithNewline: false)
        XCTAssertEqual(lf.applied(to: "a\nb"), "a\nb")
        XCTAssertEqual(lf.applied(to: "a\r\nb"), "a\nb")
    }

    /// The rule is ADD AT MOST ONE, never trim to one. A note that deliberately ends with
    /// blank lines must come back with them — otherwise ticking a box at the top of it
    /// would silently delete them.
    func testTrailingBlankLinesAreNotTrimmedAway() {
        let shape = VaultTextShape(lineEnding: .lf, endsWithNewline: true)
        XCTAssertEqual(shape.applied(to: "text\n\n\n"), "text\n\n\n")
        XCTAssertEqual(shape.applied(to: "text"), "text\n")
        XCTAssertEqual(shape.applied(to: "text\n"), "text\n", "and never doubled")
    }
}

// THE ONE FILE THIS APP DOES NOT WRITE.
final class VaultWriteExemptionTests: XCTestCase {

    func testOnlyTheRootTodayFileIsExempt() {
        XCTAssertTrue(VaultWriteExemption.isReadOnly(path: "Today.md"))
        XCTAssertTrue(VaultWriteExemption.isReadOnly(path: "./Today.md"))
        XCTAssertTrue(VaultWriteExemption.isReadOnly(path: "/Today.md"))
        // Somebody's own note that happens to share the name is an ordinary note.
        XCTAssertFalse(VaultWriteExemption.isReadOnly(path: "Projects/Today.md"))
        XCTAssertFalse(VaultWriteExemption.isReadOnly(path: "Archive/2026/Today.md"))
        XCTAssertFalse(VaultWriteExemption.isReadOnly(path: "Today.md.bak"))
        XCTAssertFalse(VaultWriteExemption.isReadOnly(path: "today.md"))
        // The five Dashboard topic files are editable — the Studio processes a tick from
        // this app exactly as it processes one from Obsidian.
        for topic in ["Tag1", "Personal", "Network", "Via-Con-Me", "Perseido"] {
            XCTAssertFalse(VaultWriteExemption.isReadOnly(path: "Dashboard/\(topic).md"))
        }
    }

    func testTheCaptionIsOnTheExemptNoteAndNowhereElse() {
        XCTAssertEqual(VaultWriteExemption.caption(path: "Today.md"),
                       "Tick items on the Today tab; this file is rewritten by the bridge.")
        XCTAssertNil(VaultWriteExemption.caption(path: "Dashboard/Tag1.md"))
    }
}
