import XCTest
import JesseNetworking
@testable import JesseTodayDisplay

/// A Today item and its strand, joined in both directions: the chip on the row, the
/// `On Today` block on the note, the board's caption, and the one opener behind them.
@MainActor
final class StrandOnTodayTests: XCTestCase {

    private let child = TodayItemStrand(slug: "Child-Strand", title: "Child Strand")

    private func wiki(_ target: String) -> TodayLink { TodayLink(target: target, kind: "wiki") }

    private func item(_ id: String, checked: Bool = false, strand: TodayItemStrand? = nil,
                      links: [TodayLink] = []) -> TodayItem {
        TodayItem(id: id, checked: checked, lead: "Lead \(id)", links: links, strand: strand)
    }

    // MARK: - The chip

    /// The row shows the strand chip, and drops the generic chip for the same strand note
    /// in every spelling, while keeping every other link.
    func testTheChipIsShownAndTheDuplicateLinkChipIsHidden() {
        let links = [wiki("todo-list/Projects/Demo/Only-Child"),
                     wiki("todo-list/Strands/Child-Strand"),
                     wiki("vault/Strands/Child-Strand.md#Status"),
                     wiki("todo-list/Strands/Other-Strand"),
                     TodayLink(target: "https://example.com/Strands/Child-Strand", kind: "url")]
        let content = TodayLinkChips.content(item("a", strand: child, links: links),
                                             showsStrand: true)
        XCTAssertEqual(content.strand, child)
        XCTAssertEqual(content.links.map(\.target),
                       ["todo-list/Projects/Demo/Only-Child",
                        "todo-list/Strands/Other-Strand",
                        "https://example.com/Strands/Child-Strand"])
    }

    /// No strand, or no opener to act on one: no strand chip, and every link stays.
    func testNoStrandOrNoOpenerLeavesTheLinksAlone() {
        let links = [wiki("todo-list/Strands/Child-Strand")]
        let unstranded = TodayLinkChips.content(item("a", links: links), showsStrand: true)
        XCTAssertNil(unstranded.strand)
        XCTAssertEqual(unstranded.links, links)
        let noOpener = TodayLinkChips.content(item("b", strand: child, links: links),
                                              showsStrand: false)
        XCTAssertNil(noOpener.strand, "a chip nobody can act on is not drawn")
        XCTAssertEqual(noOpener.links, links, "and the link it would have replaced stays")
    }

    // MARK: - On Today

    private func day() -> TodaySnapshot {
        TodaySnapshot(
            leadItems: [item("lead", strand: child)],
            sections: [
                TodaySection(name: "Do Now", items: [
                    item("open", strand: child),
                    item("done", checked: true, strand: child),
                    item("other", strand: TodayItemStrand(slug: "Child-Strand-2",
                                                          title: "Child Strand 2")),
                    item("none"),
                ]),
                TodaySection(name: "This week", items: [item("later", strand: child)]),
            ])
    }

    /// Open items only, an exact slug match, in file order.
    func testOnTodayListsOpenItemsWithAnExactSlugInFileOrder() {
        XCTAssertEqual(StrandOnToday.items(forSlug: "Child-Strand", in: day()).map(\.id),
                       ["lead", "open", "later"])
        XCTAssertEqual(StrandOnToday.items(forSlug: "child-strand", in: day()), [],
                       "the slug is matched exactly, never guessed at")
    }

    /// Nothing matches, or no day is held: an empty list, which draws no block and no
    /// caption.
    func testNoMatchHidesTheBlockAndTheCaption() {
        XCTAssertEqual(StrandOnToday.items(forSlug: "Nobody", in: day()), [])
        XCTAssertEqual(StrandOnToday.items(forSlug: "Child-Strand", in: nil), [])
        XCTAssertNil(StrandOnToday.caption(count: 0))
        XCTAssertEqual(StrandOnToday.caption(count: 3), "3 on Today")
    }

    // MARK: - The one opener

    private struct FakeLocal: TodayLocalNoteProviding {
        let path: String?
        func localNote(forTargets targets: [String]) async -> LocalVaultNote? {
            guard let path, targets == ["Strands/Child-Strand"] else { return nil }
            return LocalVaultNote(path: path, target: targets[0], markdown: "# Child Strand")
        }
    }

    private final class FakeRemote: StrandMarkdownProviding {
        let markdown: String?
        private(set) var asked: [String] = []
        init(markdown: String?) { self.markdown = markdown }
        func markdown(forSlug slug: String) async -> String? {
            asked.append(slug)
            return markdown
        }
    }

    /// The device's own copy first, and the bridge is not asked at all.
    func testTheLocalNoteWinsAndTheBridgeIsNotAsked() async {
        let remote = FakeRemote(markdown: "# From the bridge")
        let opener = StrandOpener(localNotes: FakeLocal(path: "Strands/Child-Strand.md"),
                                  remote: remote)
        await opener.resolve(slug: "Child-Strand", title: "Child Strand")
        XCTAssertEqual(opener.openedNote,
                       .local(path: "Strands/Child-Strand.md", slug: "Child-Strand",
                              title: "Child Strand"))
        XCTAssertEqual(remote.asked, [])
        XCTAssertNil(opener.opening)
    }

    /// No local copy: the bridge's markdown. Neither: the notice, naming both halves.
    func testTheBridgeIsTheFallbackAndThenTheNotice() async {
        let remote = FakeRemote(markdown: "# From the bridge")
        let opener = StrandOpener(localNotes: FakeLocal(path: nil), remote: remote)
        await opener.resolve(slug: "Child-Strand", title: "Child Strand")
        XCTAssertEqual(opener.openedNote,
                       .remote(slug: "Child-Strand", title: "Child Strand",
                               markdown: "# From the bridge"))

        let silent = FakeRemote(markdown: nil)
        let failing = StrandOpener(localNotes: nil, remote: silent)
        await failing.resolve(slug: "Child-Strand", title: "Child Strand")
        XCTAssertNil(failing.openedNote)
        XCTAssertEqual(failing.notice, StrandOpener.couldNotOpen("Child Strand"))
    }

    /// The board row opens by slug and title, the chip by the item's strand: both land on
    /// the same note through the same opener.
    func testTheBoardRowAndTheChipOpenTheSameNote() async {
        let remote = FakeRemote(markdown: "# From the bridge")
        let board = StrandOpener(localNotes: nil, remote: remote)
        await board.resolve(slug: child.slug, title: child.title)

        let chip = StrandOpener(localNotes: nil, remote: remote)
        chip.open(child)
        for _ in 0..<200 where chip.openedNote == nil { await Task.yield() }

        XCTAssertNotNil(board.openedNote)
        XCTAssertEqual(chip.openedNote, board.openedNote)
        XCTAssertEqual(remote.asked, ["Child-Strand", "Child-Strand"])
    }
}
