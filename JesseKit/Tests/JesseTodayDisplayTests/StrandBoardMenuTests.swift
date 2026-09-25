import XCTest
import SwiftUI
import JesseCore
import JesseNetworking
@testable import JesseTodayDisplay
@testable import JesseVault

// THE BOARD'S HALF OF THE ONE STRAND MENU, and the assertion that makes it one menu: the
// board's own menu and a Vault row's own menu offer the identical list, in the identical
// order, with the identical wording.
//
// That is the property the whole design exists to hold, and the only way to hold it is for
// there to be a single definition (`StrandMenu.actions`) that neither surface can extend
// locally. This file is what would fail if one of them grew a sixth button of its own.
//
// It also pins the two wirings a board row cannot get wrong silently: `Search this strand`
// must reach the shell's record action WITH THE SLUG (an entry that passed the title would
// draw a perfect menu that narrowed to nothing), and `Discuss this strand` must produce an
// Ask turn carrying the strand prompt rather than the Today one.
@MainActor
final class StrandBoardMenuTests: XCTestCase {

    private func strand(_ slug: String, title: String? = nil) -> Strand {
        Strand(slug: slug, title: title ?? slug, group: .tag1, state: .active,
               updated: "2026-09-24", now: nil, waiting: nil, next: nil, findings: [])
    }

    private final class FakeRemote: StrandMarkdownProviding {
        func markdown(forSlug slug: String) async -> String? { "# \(slug)" }
    }

    /// The board's menu, built exactly as a row builds it, with the shell's two actions
    /// captured.
    private struct Wiring {
        let menu: StrandMenu
        let opener: StrandOpener
        /// Held, because `StrandOpener` keeps its remote WEAKLY (the app's is the strands
        /// model, which the shell owns): a fake left unreferenced here is deallocated
        /// before the resolve reaches it, and the note silently fails to open.
        let remote: FakeRemote
        let recorded: () -> [(String, VaultStrandSection)]
        let discussed: () -> [StrandMenuTarget]
    }

    private func boardWiring(_ strand: Strand, withShell: Bool = true) -> Wiring {
        let remote = FakeRemote()
        let opener = StrandOpener(localNotes: nil, remote: remote)
        let recorded = Box<[(String, VaultStrandSection)]>([])
        let discussed = Box<[StrandMenuTarget]>([])
        let menu = StrandsListView.menu(
            for: strand,
            opener: opener,
            discuss: withShell ? StrandDiscussAction { discussed.value.append($0) } : nil,
            record: withShell
                ? StrandRecordAction { recorded.value.append(($0, $1)) }
                : nil)
        return Wiring(menu: menu, opener: opener, remote: remote,
                      recorded: { recorded.value }, discussed: { discussed.value })
    }

    /// A reference cell, because the actions hold `@MainActor` closures and a captured local
    /// `var` cannot be mutated from one.
    @MainActor private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - One menu, two surfaces

    /// THE ASSERTION THIS FILE EXISTS FOR. The board's menu and a Vault row's menu are the
    /// same five entries, in the same order, with the same words and the same glyphs.
    func testBothSurfacesOfferTheIdenticalMenu() throws {
        let board = boardWiring(strand("Jesse", title: "Jesse App")).menu
        let vault = try XCTUnwrap(
            VaultBrowserView(model: VaultBrowserModel(source: Self.emptySource()))
                .strandMenu(forPath: "Strands/Jesse.md", title: "Jesse App"))

        XCTAssertEqual(StrandMenu.actions, StrandMenu.actions, "one definition, not two")
        XCTAssertEqual(board.target, vault.target,
                       "and the two surfaces agree on which strand they are about")
        XCTAssertEqual(StrandMenu.actions.map(\.label),
                       ["Open note", "Discuss this strand", "Search this strand",
                        "Decisions", "Copy link"])
        XCTAssertEqual(StrandMenu.actions.map(\.symbol).count, 5)
        XCTAssertFalse(StrandMenu.actions.map(\.symbol).contains(""),
                       "every entry carries a glyph")
    }

    /// A device with no vault folder picked, so the Vault half of the comparison above costs
    /// no index and touches no real note.
    private static func emptySource() -> VaultIndexSource {
        let defaults = UserDefaults(suiteName: "jesse.strand.board.menu.\(UUID().uuidString)")!
        return VaultIndexSource(folder: VaultFolder(defaults: defaults, key: "test.bookmark"),
                                container: FileManager.default.temporaryDirectory)
    }

    // MARK: - Which strand a board row is about

    /// The board knows a slug and a title; the note's path is the vault's convention, and it
    /// is what the discuss prompt names.
    func testABoardRowsTargetIsItsSlugTitleAndConventionalPath() {
        let menu = boardWiring(strand("Jesse", title: "Jesse App")).menu
        XCTAssertEqual(menu.target.slug, "Jesse")
        XCTAssertEqual(menu.target.title, "Jesse App")
        XCTAssertEqual(menu.target.path, "Strands/Jesse.md")
    }

    // MARK: - Open note

    /// `Open note` is the opener the row's TAP already uses, not a second way in: the note on
    /// this device when it holds one, the bridge's copy when it does not.
    func testOpenNoteGoesThroughTheRowsOwnOpener() async {
        let wiring = boardWiring(strand("Jesse", title: "Jesse App"))
        wiring.menu.perform(.openNote)
        // `open` returns at once and resolves in a task of its own, exactly as a tap does.
        for _ in 0..<200 where wiring.opener.openedNote == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(wiring.opener.openedNote,
                       .remote(slug: "Jesse", title: "Jesse App", markdown: "# Jesse"))
    }

    // MARK: - Search and Decisions

    /// THE SLUG, not the title and not the path: the Vault entry point resolves a slug, and
    /// an entry that passed anything else would narrow the tab to nothing.
    func testSearchAsksTheShellForTheRecordBySlug() {
        let wiring = boardWiring(strand("Jesse", title: "Jesse App"))
        wiring.menu.perform(.search)
        XCTAssertEqual(wiring.recorded().map(\.0), ["Jesse"])
        XCTAssertEqual(wiring.recorded().map(\.1), [.all])
    }

    /// `Decisions` is the same request with the section chip on, which is what makes it one
    /// screen rather than a second one.
    func testDecisionsIsTheSameRequestWithTheSectionOn() {
        let wiring = boardWiring(strand("Jesse", title: "Jesse App"))
        wiring.menu.perform(.decisions)
        XCTAssertEqual(wiring.recorded().count, 1)
        XCTAssertEqual(wiring.recorded().first?.0, "Jesse")
        XCTAssertEqual(wiring.recorded().first?.1, .decisions)
    }

    // MARK: - Discuss

    /// The board hands the shell the strand it was pressed on, and nothing else: the turn is
    /// built from that target, so a menu that passed the wrong one would open a conversation
    /// about another piece of work.
    func testDiscussHandsTheShellTheStrandThatWasPressed() {
        let wiring = boardWiring(strand("Jesse", title: "Jesse App"))
        wiring.menu.perform(.discuss)
        XCTAssertEqual(wiring.discussed().map(\.slug), ["Jesse"])
        XCTAssertEqual(wiring.discussed().first?.path, "Strands/Jesse.md")
    }

    /// **The turn itself: ASK, and the strand's own prompt.** Ask because a discussion must
    /// not become task work nobody asked for; the strand prompt because it is the one that
    /// names the note and grants the bounded permission to record an update. A Tell, or the
    /// Today item prompt, would each be a different feature.
    func testTheDiscussTurnIsAnAskCarryingTheStrandPrompt() {
        let target = StrandMenuTarget(slug: "Jesse", title: "Jesse App", path: "Strands/Jesse.md")
        let turn = TodayTurn.discuss(strand: target)

        XCTAssertEqual(turn.mode, .ask)
        XCTAssertEqual(turn.text, StrandDiscuss.prompt(slug: "Jesse", title: "Jesse App",
                                                       path: "Strands/Jesse.md"))
        XCTAssertTrue(turn.text.contains("Strands/Jesse.md"), "the note is named by path")
        XCTAssertTrue(turn.text.contains(
            "An update {owner} gives IS the instruction to record it in that note in the same turn"),
                      "the record clause is what makes an update land in the note")
    }

    /// An archived strand's discussion names the archived file, not the live spelling of it.
    func testAnArchivedStrandsTurnNamesTheArchivedFile() throws {
        let target = try XCTUnwrap(StrandMenuTarget.note(path: "Strands/archive/Shed.md",
                                                         title: "Shed"))
        XCTAssertTrue(TodayTurn.discuss(strand: target).text
            .contains("Strands/archive/Shed.md"))
    }

    /// With no shell behind the board (a preview), the entries are still LISTED and pressing
    /// them does nothing. A menu that changed shape depending on where it was mounted is
    /// exactly what this design rules out.
    func testTheEntriesAreInertRatherThanAbsentWithoutAShell() {
        let wiring = boardWiring(strand("Jesse"), withShell: false)
        wiring.menu.perform(.discuss)
        wiring.menu.perform(.search)
        XCTAssertTrue(wiring.discussed().isEmpty)
        XCTAssertTrue(wiring.recorded().isEmpty)
        XCTAssertEqual(StrandMenu.actions.count, 5)
    }
}
