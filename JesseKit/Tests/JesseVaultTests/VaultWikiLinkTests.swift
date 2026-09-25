import XCTest
@testable import JesseVault

// `[[wiki links]]`: what a target is, and which file it names.
//
// The resolver's three steps and its refusal to guess are the whole point of this file.
// A link that quietly opens the wrong `Overview.md` is worse than a link that says it
// cannot decide, and only a test can hold that line.

final class VaultWikiLinkTests: XCTestCase {

    // MARK: - Reading the targets out of a note

    func testATargetLosesItsAliasItsHeadingAndItsExtension() {
        XCTAssertEqual(VaultWikiLink.normalized("People/Marta Ruggeri|Marta"),
                       "People/Marta Ruggeri")
        XCTAssertEqual(VaultWikiLink.normalized("Workshop/Overview#Benches"),
                       "Workshop/Overview")
        XCTAssertEqual(VaultWikiLink.normalized("Workshop/Overview.md"), "Workshop/Overview")
        XCTAssertEqual(VaultWikiLink.normalized("  /Workshop/Kiln/  "), "Workshop/Kiln")
        XCTAssertEqual(VaultWikiLink.normalized("./Kiln"), "Kiln")
    }

    func testEveryTargetInSourceOrderWithoutDuplicates() {
        let line = "See [[A]], then [[B|bee]], then [[A]] again, and [[C#top]]."
        XCTAssertEqual(VaultWikiLink.targets(in: line), ["A", "B", "C"])
    }

    /// An unclosed `[[` is not a link and must not eat the rest of the note.
    func testAnUnclosedBracketPairYieldsNothing() {
        XCTAssertEqual(VaultWikiLink.targets(in: "a [[ b c"), [])
        XCTAssertEqual(VaultWikiLink.targets(in: "[[]]"), [])
    }

    func testTheFileNameOfATargetIsItsLastComponentPlusTheExtension() {
        XCTAssertEqual(VaultWikiLink.fileName(for: "Workshop/Kiln-Rebuild"), "Kiln-Rebuild.md")
        XCTAssertEqual(VaultWikiLink.fileName(for: "Kiln-Rebuild"), "Kiln-Rebuild.md")
    }

    // MARK: - Resolution, step by step

    private let paths = [
        "Workshop/Kiln-Rebuild.md",
        "Workshop/Overview.md",
        "Bicycle/Overview.md",
        "Suppliers/Terrasole.md",
        "People/Marta Ruggeri.md",
    ]

    /// Step 1: a link that spells the whole path means that file.
    func testAnExactPathResolvesToItself() {
        XCTAssertEqual(VaultWikiLink.resolve(target: "Workshop/Kiln-Rebuild", among: paths),
                       "Workshop/Kiln-Rebuild.md")
    }

    /// Step 2, and the case that matters most in the real vault: links are written as full
    /// paths from the WORKSPACE root (`todo-list/…`) while the synced folder starts one
    /// level in, so the file name is what actually identifies the note.
    func testAUniqueFileNameResolvesEvenWhenThePathPrefixIsWrong() {
        XCTAssertEqual(
            VaultWikiLink.resolve(target: "todo-list/Workshop/Kiln-Rebuild", among: paths),
            "Workshop/Kiln-Rebuild.md")
        XCTAssertEqual(VaultWikiLink.resolve(target: "Terrasole", among: paths),
                       "Suppliers/Terrasole.md")
    }

    /// Step 3: a name typed in the wrong case still resolves, as long as only one file
    /// answers to it.
    func testACaseFoldedFileNameResolvesWhenItIsUnique() {
        XCTAssertEqual(VaultWikiLink.resolve(target: "terrasole", among: paths),
                       "Suppliers/Terrasole.md")
        XCTAssertEqual(VaultWikiLink.resolve(target: "marta ruggeri", among: paths),
                       "People/Marta Ruggeri.md")
    }

    /// TWO FILES, NO ANSWER. `Overview.md` exists twice, so a bare `[[Overview]]` resolves
    /// to nothing at all rather than to whichever one sorts first — the same refusal
    /// Obsidian makes, and the reason it is a test rather than a comment.
    func testAnAmbiguousFileNameResolvesToNothing() {
        XCTAssertNil(VaultWikiLink.resolve(target: "Overview", among: paths))
        XCTAssertNil(VaultWikiLink.resolve(target: "overview", among: paths))
        XCTAssertEqual(VaultWikiLink.resolve(target: "Workshop/Overview", among: paths),
                       "Workshop/Overview.md",
                       "spelling the path is how a reader disambiguates, and it still works")
    }

    /// THE STRAY FILE. Tapping an unresolved `[[todo-list/…]]` link in Obsidian creates an
    /// empty note at that literal path, and Sync copies it everywhere. It must never be the
    /// answer: not by exact path (it would open the empty file), and not as a second file
    /// with the draft's name (it would make the real draft ambiguous).
    func testAStrayTodoListFileIsNeverTheAnswer() {
        let withStrays = [
            "Projects/drafts/2026-09-17-0856-Permesso-Kits.md",
            "todo-list/Projects/drafts/2026-09-17-0856-Permesso-Kits.md",
            "Projects/drafts/archive/2026-09-17-1455-talk-outline-v4.md",
            "todo-list/Projects/drafts/archive/2026-09-17-1455-talk-outline-v4.md",
        ]
        XCTAssertEqual(
            VaultWikiLink.resolve(target: "todo-list/Projects/drafts/2026-09-17-0856-Permesso-Kits",
                                  among: withStrays),
            "Projects/drafts/2026-09-17-0856-Permesso-Kits.md")
        // A draft archived since the link was written: found by name, the stray ignored.
        XCTAssertEqual(
            VaultWikiLink.resolve(target: "todo-list/Projects/drafts/2026-09-17-1455-talk-outline-v4",
                                  among: withStrays),
            "Projects/drafts/archive/2026-09-17-1455-talk-outline-v4.md")
        // Only the stray exists: nothing, rather than an empty note.
        XCTAssertNil(VaultWikiLink.resolve(
            target: "todo-list/Projects/drafts/Gone",
            among: ["todo-list/Projects/drafts/Gone.md"]))
    }

    func testAMissingTargetResolvesToNothing() {
        XCTAssertNil(VaultWikiLink.resolve(target: "Nowhere", among: paths))
        XCTAssertNil(VaultWikiLink.resolve(target: "", among: paths))
        XCTAssertNil(VaultWikiLink.resolve(target: "   ", among: paths))
    }
}
