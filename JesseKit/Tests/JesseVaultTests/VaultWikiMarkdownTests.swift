import XCTest
@testable import JesseVault

/// `[[WIKI LINKS]]` IN A CHAT REPLY: what the rewrite produces, and what it must never
/// do to a reply that merely contains brackets.
final class VaultWikiMarkdownTests: XCTestCase {

    /// The whole point, in one line: an aliased link renders as the ALIAS and carries
    /// the target that resolves to the right vault file.
    func testAnAliasedLinkRendersTheAliasAndCarriesTheTarget() throws {
        let out = VaultWikiMarkdown.linked(
            "See [[todo-list/Strands/Strands-System|the strands note]] for where it stands.")

        XCTAssertEqual(
            out,
            "See [the strands note](jesse://wiki?target=todo-list/Strands/Strands-System) for where it stands.")

        // And the URL round trips to the target the resolver takes.
        let url = try XCTUnwrap(URL(string: "jesse://wiki?target=todo-list/Strands/Strands-System"))
        let route = try XCTUnwrap(VaultWikiRoute.parse(url))
        XCTAssertEqual(route.target, "todo-list/Strands/Strands-System")

        // Which, against a vault whose folder is one level in from the workspace root,
        // is `Strands/Strands-System.md` — the file the reader opens.
        XCTAssertEqual(
            VaultWikiLink.resolve(target: route.target,
                                  among: ["Strands/Strands-System.md", "Today.md"]),
            "Strands/Strands-System.md")
    }

    /// With no alias, the label is the file name. A reply is a narrow column and
    /// `todo-list/Projects/Tag1/Scolta/Engineering/Composer-Advisory-Blocking-Runbook`
    /// is not a label.
    func testWithoutAnAliasTheLabelIsTheFileName() {
        XCTAssertEqual(
            VaultWikiMarkdown.linked("[[todo-list/Projects/Perseido/Perseido]]"),
            "[Perseido](jesse://wiki?target=todo-list/Projects/Perseido/Perseido)")
    }

    /// A `#heading` is dropped from the label AND from the target: the label because it
    /// is noise in a chip, the target because the resolver takes a file.
    func testAHeadingIsDroppedFromBothHalves() {
        XCTAssertEqual(
            VaultWikiMarkdown.linked("[[Perseido#Billing]]"),
            "[Perseido](jesse://wiki?target=Perseido)")
    }

    func testSeveralLinksInOneLine() {
        XCTAssertEqual(
            VaultWikiMarkdown.linked("[[Argus]] and [[Netgrasp|the other one]]."),
            "[Argus](jesse://wiki?target=Argus) and [the other one](jesse://wiki?target=Netgrasp).")
    }

    /// LOSS FREE. A reply that mentions brackets, or opens a pair it never closes, comes
    /// back with every character it went in with.
    func testNothingIsLost() {
        for text in ["No links here at all.",
                     "An unclosed [[bracket and then some prose.",
                     "Empty [[]] brackets.",
                     "An array literal: a[[0]] is not a wiki link… but it parses as one target."] {
            let out = VaultWikiMarkdown.linked(text)
            // Either untouched, or rewritten into something that still contains every
            // word of the original.
            for word in text.split(separator: " ") where !word.contains("[") {
                XCTAssertTrue(out.contains(word), "lost \(word) from: \(text)")
            }
        }
        XCTAssertEqual(VaultWikiMarkdown.linked("No links here at all."), "No links here at all.")
        XCTAssertEqual(VaultWikiMarkdown.linked("An unclosed [[bracket and then some prose."),
                       "An unclosed [[bracket and then some prose.")
        XCTAssertEqual(VaultWikiMarkdown.linked("Empty [[]] brackets."), "Empty [[]] brackets.")
    }

    /// A note name carrying a bracket is escaped rather than renamed. The label is what
    /// the reader sees, and silently editing a note's name in a reply is worse than a
    /// backslash the parser eats.
    func testBracketsInALabelAreEscaped() {
        XCTAssertEqual(VaultWikiMarkdown.linked("[[Notes/A [draft] thing]]"),
                       "[A \\[draft\\] thing](jesse://wiki?target=Notes/A%20%5Bdraft%5D%20thing)")
    }

    /// The route claims `jesse://wiki` and NOTHING else — not the citation route it sits
    /// beside, and not the share extension's foregrounding URL.
    func testTheRouteClaimsOnlyItsOwnHost() throws {
        XCTAssertNil(VaultWikiRoute.parse(URL(string: "jesse://note?path=Today.md")!))
        XCTAssertNil(VaultWikiRoute.parse(URL(string: "jesse://share-audio")!))
        XCTAssertNil(VaultWikiRoute.parse(URL(string: "https://example.com/wiki?target=x")!))
        XCTAssertNil(VaultWikiRoute.parse(URL(string: "jesse://wiki")!))
        XCTAssertNil(VaultWikiRoute.parse(URL(string: "jesse://wiki?target=")!))
        // And the citation route does not claim this one either.
        XCTAssertNil(VaultNoteRoute.parse(URL(string: "jesse://wiki?target=Argus")!))
    }

    /// One sentence for a note that is not here, shared by the reader and the chat tap.
    func testTheMissingCaptionIsOneSentence() {
        XCTAssertEqual(VaultWikiLink.missingCaption(targets: ["todo-list/Strands/Argus"]),
                       "Argus is not in this copy of the vault.")
        XCTAssertEqual(VaultWikiLink.missingCaption(targets: ["A", "B"]),
                       "Not in this copy of the vault: A, B.")
        XCTAssertNil(VaultWikiLink.missingCaption(targets: []))
    }
}
