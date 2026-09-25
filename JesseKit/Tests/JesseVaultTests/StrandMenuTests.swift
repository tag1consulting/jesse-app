import XCTest
import SwiftUI
@testable import JesseVault

// THE ONE STRAND MENU, and the half of it this target owns: what the menu is, which strand
// it is about, what each entry does, and what a row of the Vault tab wires it to.
//
// A `View`'s body cannot be pressed from a unit test, so what is asserted is everything
// decided BEFORE SwiftUI renders: the action list and its order, the dispatch each entry
// runs, the link that is copied, and — the one that would actually regress — that the Vault
// tab's own rows wire `Search` and `Decisions` to THIS model rather than to nothing. The
// Today board's half of the same menu is asserted in `JesseTodayDisplayTests`, including
// the comparison that proves the two surfaces offer the identical list.
@MainActor
final class StrandMenuTests: XCTestCase {

    // MARK: - Which strand a row is about

    func testAStrandNoteBecomesATargetAndAnythingElseDoesNot() {
        let live = StrandMenuTarget.note(path: "Strands/Kiln.md", title: "Kiln")
        XCTAssertEqual(live?.slug, "Kiln")
        XCTAssertEqual(live?.path, "Strands/Kiln.md")
        XCTAssertEqual(live?.title, "Kiln")

        // The archive is IN: a finished strand is still a strand, and its record is why the
        // scope reaches the archive at all.
        let archived = StrandMenuTarget.note(path: "Strands/archive/Shed.md", title: "Shed")
        XCTAssertEqual(archived?.slug, "Shed")
        XCTAssertEqual(archived?.path, "Strands/archive/Shed.md")

        // And everything else in a 7,600 note vault is not a strand.
        XCTAssertNil(StrandMenuTarget.note(path: "Projects/Elsewhere.md", title: "Elsewhere"))
        XCTAssertNil(StrandMenuTarget.note(path: "Today.md", title: "Today"))
        XCTAssertNil(StrandMenuTarget.note(path: "Knowledge/Strands-Guidelines.md",
                                           title: "Guidelines"),
                     "a note merely NAMED for strands is not one")
    }

    /// The board's case: it holds a wire `Strand`, which already knows its own note path,
    /// so the target is built from that rather than from a second spelling of the
    /// convention.
    func testALiveTargetCarriesTheNotePathItWasGiven() {
        let target = StrandMenuTarget(slug: "Jesse", title: "Jesse App", path: "Strands/Jesse.md")
        XCTAssertEqual(target.path, "Strands/Jesse.md")
        XCTAssertEqual(target.slug, "Jesse")
    }

    /// The link the vault's own notes use, and the one `Copy link` puts on the pasteboard.
    /// ALWAYS the live spelling, even for an archived note: that is the link a project file
    /// should carry, and it keeps working if the strand is revived.
    func testTheWikiLinkIsTheLiveSpellingEvenForAnArchivedNote() {
        XCTAssertEqual(StrandMenuTarget(slug: "Jesse", title: "Jesse App", path: "Strands/Jesse.md").wikiLink,
                       "[[todo-list/Strands/Jesse]]")
        let archived = StrandMenuTarget.note(path: "Strands/archive/Shed.md", title: "Shed")
        XCTAssertEqual(archived?.wikiLink, "[[todo-list/Strands/Shed]]")
    }

    // MARK: - The menu itself

    /// THE LIST, in order. One definition, rendered by both surfaces; a change here is a
    /// change to both, which is the property the whole file exists for.
    func testTheMenuIsFiveActionsInOneOrder() {
        XCTAssertEqual(StrandMenu.actions,
                       [.openNote, .discuss, .search, .decisions, .copyLink])
        XCTAssertEqual(StrandMenu.actions.map(\.label),
                       ["Open note", "Discuss this strand", "Search this strand",
                        "Decisions", "Copy link"])
    }

    /// Only the two record entries name a section, and they name different ones: `Search` is
    /// the whole note, `Decisions` the same view with the chip on.
    func testOnlyTheRecordEntriesNameASection() {
        XCTAssertEqual(StrandMenuAction.search.recordSection, .all)
        XCTAssertEqual(StrandMenuAction.decisions.recordSection, .decisions)
        for action in [StrandMenuAction.openNote, .discuss, .copyLink] {
            XCTAssertNil(action.recordSection)
        }
    }

    /// No dash punctuation in anything a person reads off the screen.
    func testNoLabelCarriesDashPunctuation() {
        for label in StrandMenu.actions.map(\.label) {
            for dash in ["\u{2014}", "\u{2013}", "--"] {
                XCTAssertFalse(label.contains(dash), "\(label) carries \(dash)")
            }
        }
    }

    // MARK: - What each entry does

    /// Every entry calls the closure it is supposed to, and no other. Driven through
    /// `perform`, which is the whole dispatch: a menu whose buttons each closed over their
    /// own logic could only be checked by tapping it.
    func testEachEntryRunsItsOwnHandlerAndNothingElse() {
        var opened = 0
        var discussed = 0
        var sections: [VaultStrandSection] = []
        var copied: [String] = []
        let menu = StrandMenu(target: StrandMenuTarget(slug: "Jesse", title: "Jesse App",
                                                       path: "Strands/Jesse.md"),
                              onOpenNote: { opened += 1 },
                              onDiscuss: { discussed += 1 },
                              onShowRecord: { sections.append($0) },
                              copy: { copied.append($0) })

        menu.perform(.openNote)
        XCTAssertEqual([opened, discussed, sections.count, copied.count], [1, 0, 0, 0])

        menu.perform(.discuss)
        XCTAssertEqual([opened, discussed, sections.count, copied.count], [1, 1, 0, 0])

        menu.perform(.search)
        menu.perform(.decisions)
        XCTAssertEqual(sections, [.all, .decisions])

        menu.perform(.copyLink)
        XCTAssertEqual(copied, ["[[todo-list/Strands/Jesse]]"])
        XCTAssertEqual([opened, discussed], [1, 1], "nothing else ran")
    }

    /// A screen with no shell behind it (a preview) still LISTS Discuss, and pressing it
    /// does nothing rather than crashing. The entry is never hidden: a menu that changed
    /// shape depending on where it was mounted is the failure this design rules out.
    func testDiscussIsInertRatherThanAbsentWithoutAShell() {
        let menu = StrandMenu(target: StrandMenuTarget(slug: "Jesse", title: "Jesse App",
                                                       path: "Strands/Jesse.md"),
                              onOpenNote: {}, onDiscuss: nil, onShowRecord: { _ in })
        menu.perform(.discuss)
        XCTAssertEqual(StrandMenu.actions.count, 5, "still five entries")
    }

    // MARK: - The Vault tab's own rows

    /// The Vault tab answers the two record entries ITSELF, by narrowing its own model,
    /// because the record is already on screen. This drives the view's real factory over a
    /// real index, so a row wired to nothing would fail here.
    func testAVaultRowNarrowsThisTabInPlace() async throws {
        let fixture = try await StrandMenuFixture.make()
        let view = VaultBrowserView(model: fixture.model)
        let menu = try XCTUnwrap(view.strandMenu(forPath: "Strands/Kiln.md", title: "Kiln"))

        XCTAssertEqual(menu.target.slug, "Kiln")

        menu.perform(.decisions)
        await fixture.model.awaitPendingSearch()
        XCTAssertEqual(fixture.model.strand, "Strands/Kiln.md")
        XCTAssertEqual(fixture.model.section, .decisions)
        XCTAssertEqual(fixture.model.scope, .strands, "narrowing to a strand implies the scope")
        XCTAssertFalse(fixture.model.sectionLines.isEmpty, "and the lines are really there")

        menu.perform(.search)
        await fixture.model.awaitPendingSearch()
        XCTAssertEqual(fixture.model.section, .all, "Search is the whole note")
        XCTAssertEqual(fixture.model.strand, "Strands/Kiln.md")
    }

    /// An archived row narrows to the archived note, so the menu on a finished strand is not
    /// quietly a menu about a live one.
    func testAnArchivedVaultRowNarrowsToTheArchivedNote() async throws {
        let fixture = try await StrandMenuFixture.make()
        let view = VaultBrowserView(model: fixture.model)
        let menu = try XCTUnwrap(view.strandMenu(forPath: "Strands/archive/Shed.md",
                                                 title: "Shed"))
        menu.perform(.search)
        await fixture.model.awaitPendingSearch()
        XCTAssertEqual(fixture.model.strand, "Strands/archive/Shed.md")
    }

    /// THE ROW THAT GETS NO MENU. Most of this tab is not strands, and those rows keep the
    /// long press they had — which is why the absence is an absent menu and not an empty one.
    func testANonStrandVaultRowHasNoMenuAtAll() async throws {
        let fixture = try await StrandMenuFixture.make()
        let view = VaultBrowserView(model: fixture.model)
        XCTAssertNil(view.strandMenu(forPath: "Projects/Elsewhere.md", title: "Elsewhere"))
        XCTAssertNil(view.strandMenu(forPath: "Today.md", title: "Today"))
    }
}

// MARK: - The fixture

/// A real temporary vault with two live strands, one archived, and one note that is not a
/// strand at all, indexed for real. The peer of `VaultStrandRecordTests`'s own setup, held
/// as a value so the tests above read as assertions rather than as setup.
@MainActor
struct StrandMenuFixture {
    let root: URL
    let databaseDirectory: URL
    let model: VaultBrowserModel

    static func make() async throws -> StrandMenuFixture {
        let root = VaultFixture.makeDirectory()
        let databaseDirectory = VaultFixture.makeDirectory()
        VaultFixture.write("""
            ---
            state: active
            updated: 2026-09-25
            ---
            # Kiln

            **Now:** Firing next week.

            ## Decisions
            - 2026-09-01 The bridge wall is rebuilt in soft brick.

            ## Status
            - 2026-09-24 Bricks arrived.
            """, to: "Strands/Kiln.md", in: root)
        VaultFixture.write("""
            ---
            state: done
            updated: 2026-08-30
            ---
            # Shed

            ## Decisions
            - 2026-08-15 Tin roof.
            """, to: "Strands/archive/Shed.md", in: root)
        VaultFixture.write("# Elsewhere\n\nNot a strand.\n", to: "Projects/Elsewhere.md",
                           in: root)

        let defaults = UserDefaults(suiteName: "jesse.strand.menu.tests.\(UUID().uuidString)")!
        let folder = VaultFolder(defaults: defaults, key: "test.bookmark")
        try folder.adopt(url: root)
        let source = VaultIndexSource(folder: folder, container: databaseDirectory)
        let model = VaultBrowserModel(source: source, debounce: .zero)
        await model.indexer.reindexNow()
        model.refresh()
        return StrandMenuFixture(root: root, databaseDirectory: databaseDirectory, model: model)
    }
}
