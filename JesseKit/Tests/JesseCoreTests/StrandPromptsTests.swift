import XCTest
@testable import JesseCore

// THE STRAND DISCUSS PROMPT, pinned the way `TodayPromptsTests` pins the two Today ones.
// Read that file's header first; the three properties it names (the embedded text is
// verbatim, routine names appear only inside the negative sentence, the owner is a
// placeholder and never a name) are asserted here too.
//
// This prompt has a fourth property the Today ones do not, and it is the one worth the
// most care: it GRANTS A WRITE. An update Jeremy gives in the conversation is to be
// recorded in the strand's note in the same turn, without a permission question. That
// grant is bounded twice — to one file, and to one reason — and both bounds are asserted
// below, because a reword that loses either turns a discussion about work in progress into
// an agent with a licence to tidy the vault.

final class StrandPromptsTests: XCTestCase {

    private let slug = "Jesse"
    private let title = "Jesse App and Bridge"
    private let path = "Strands/Jesse.md"

    private var prompt: String {
        StrandDiscuss.prompt(slug: slug, title: title, path: path)
    }

    // MARK: - What it is about

    func testItOpensByNamingTheStrandAndItsNote() {
        XCTAssertTrue(prompt.hasPrefix("{Owner} wants to discuss the strand \(title),"),
                      "the title is what Jeremy just pressed, so it leads")
        XCTAssertTrue(prompt.contains("status note is the vault file at \(path)"),
                      "the file to open, named as a path")
        XCTAssertTrue(prompt.contains("slug, \(slug)"),
                      "the name every other note refers to this strand by")
    }

    /// An archived strand is still a strand, and the prompt must name the file that
    /// actually exists rather than the live spelling of it.
    func testItNamesAnArchivedNotesOwnPath() {
        let archived = StrandDiscuss.prompt(slug: "Shed", title: "Shed Rebuild",
                                            path: "Strands/archive/Shed.md")
        XCTAssertTrue(archived.contains("Strands/archive/Shed.md"))
    }

    func testItSaysToReadTheNoteFirstAndThenWhatItLinks() {
        XCTAssertTrue(prompt.contains("Read that note in full first"))
        XCTAssertTrue(prompt.contains("## Drafts"))
        XCTAssertTrue(prompt.contains("## Research"))
        XCTAssertTrue(prompt.contains("## Vault"))
    }

    /// The discussion goes BOTH ways, said in the prompt's own words: without this the
    /// agent treats an update as a question and answers it instead of recording it.
    func testItSaysTheDiscussionGoesBothWays() {
        XCTAssertTrue(prompt.contains("A strand discussion goes both ways"))
        for update in ["a run that finished", "a decision made",
                       "a step dropped or reordered"] {
            XCTAssertTrue(prompt.contains(update), "\(update) must be named as an update")
        }
    }

    // MARK: - The grant, and its two bounds

    /// THE GRANT. An update Jeremy gives IS the instruction to record it, in the same turn,
    /// and without a permission question — which is what makes "the run finished" land in
    /// the note instead of coming back as "shall I write that down?".
    func testAnUpdateIsItselfTheInstructionToRecordIt() {
        XCTAssertTrue(prompt.contains(
            "An update {owner} gives IS the instruction to record it in that note in the same turn"))
        XCTAssertTrue(prompt.contains("through the normal strand update procedure"))
        XCTAssertTrue(prompt.contains("without asking permission first"))
    }

    /// BOUND ONE: one file. A strand note links drafts, research and project files, and a
    /// discussion that could edit those is a discussion that can rewrite the Dashboard from
    /// a passing remark.
    func testTheGrantIsBoundedToThatOneNote() {
        XCTAssertTrue(prompt.contains("Write to that one note, for that one reason, and to no other file."))
        XCTAssertTrue(prompt.contains("Scope: this one strand only."))
    }

    /// BOUND TWO: one reason, and no task work. The Ask floor says it too, but the prompt
    /// carries a write permission, so it says it itself rather than relying on the wrapper.
    func testItForbidsTaskWorkNobodyAskedFor() {
        XCTAssertTrue(prompt.contains("do not do task work {owner} has not asked for"))
    }

    // MARK: - The routing assertion

    /// The same assertion `TodayDiscuss` carries, for the same reason: the vault's morning
    /// routines are selected by what a turn's text SAYS, so "start of day" anywhere in the
    /// positive half of the instruction would read as a request to run it, and a chat about
    /// one strand would rebuild the whole day.
    func testItMentionsStartOfDayOnlyInsideTheNegativeScopeSentence() {
        XCTAssertEqual(prompt.components(separatedBy: "start of day").count - 1, 1,
                       "exactly one mention of the routine name")
        let negative = "Do not run start of day, scanners, currency, or cheatsheets"
        XCTAssertTrue(prompt.contains(negative))
        XCTAssertFalse(prompt.replacingOccurrences(of: negative, with: "")
            .contains("start of day"), "the only mention is the one that forbids it")
    }

    func testItForbidsEveryOtherRoutineToo() {
        XCTAssertTrue(prompt.contains("do not start any other routine"))
        for routine in ["scanners", "currency", "cheatsheets"] {
            XCTAssertTrue(prompt.contains(routine), "\(routine) must be named and forbidden")
        }
    }

    // MARK: - The owner

    /// A PLACEHOLDER, never a name: the bridge renders `{Owner}` / `{owner}` /
    /// `{owner_pronoun}` from its own deployment data, so a fresh clone of this repo belongs
    /// to whoever installed it.
    func testTheOwnerIsAPlaceholderAndNeverAName() {
        XCTAssertTrue(prompt.contains("{Owner}"))
        XCTAssertTrue(prompt.contains("{owner}"))
        XCTAssertTrue(prompt.contains("{owner_pronoun}"))
        XCTAssertFalse(prompt.contains("Jeremy"), "no name is the app's to know")
    }

    /// `{Owner}` is the sentence-start spelling and `{owner}` the mid-sentence one, so the
    /// capitalized form must never appear mid-sentence. Asserted structurally: every
    /// occurrence of `{Owner}` either starts the prompt or follows a sentence end.
    func testTheCapitalizedPlaceholderOnlyStartsASentence() {
        var searchRange = prompt.startIndex..<prompt.endIndex
        while let found = prompt.range(of: "{Owner}", range: searchRange) {
            if found.lowerBound != prompt.startIndex {
                let before = prompt[prompt.index(before: found.lowerBound)]
                XCTAssertTrue(before == " " || before == "\n", "unexpected \(before)")
                // Two characters back is the end of the previous sentence.
                let punctuation = prompt[prompt.index(found.lowerBound, offsetBy: -2)]
                XCTAssertTrue(".:\n".contains(punctuation),
                              "{Owner} mid-sentence: use {owner} there")
            }
            searchRange = found.upperBound..<prompt.endIndex
        }
    }

    // MARK: - No dashes

    /// No em dash, en dash or double hyphen anywhere in a wording a person reads back out
    /// of a conversation. The vault's own writing rule, and this text is quoted into it.
    func testItCarriesNoDashPunctuation() {
        for dash in ["\u{2014}", "\u{2013}", "--"] {
            XCTAssertFalse(prompt.contains(dash), "dash punctuation: \(dash)")
        }
    }
}
