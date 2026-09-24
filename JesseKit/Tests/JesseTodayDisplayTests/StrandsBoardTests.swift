import XCTest
import JesseNetworking
@testable import JesseTodayDisplay

/// THE BOARD: how it is ordered, what one row says, and what it shows with the bridge
/// out of reach.
@MainActor
final class StrandsBoardTests: XCTestCase {

    private func strand(_ slug: String,
                        group: TodayProject = .unfiled,
                        state: StrandState = .active,
                        updated: String = "2026-09-24",
                        now: String? = nil,
                        waiting: StrandWaiting? = nil,
                        next: StrandNext? = nil,
                        findings: [StrandFinding] = []) -> Strand {
        Strand(slug: slug, title: slug, group: group, state: state, updated: updated,
               now: now, waiting: waiting, next: next, findings: findings)
    }

    // MARK: - The lens

    /// `By group` puts the five Dashboard projects in Dashboard order with `unfiled`
    /// last, and it is the SAME order the day screen's `by project` uses — both read
    /// `TodayProject.allCases`, so the two screens cannot disagree about where Perseido
    /// sits.
    func testByGroupUsesDashboardOrderWithUnfiledLast() {
        let board = [strand("E", group: .unfiled),
                     strand("D", group: .perseido),
                     strand("C", group: .viaConMe),
                     strand("B", group: .network),
                     strand("A", group: .personal),
                     strand("Z", group: .tag1)]

        let groups = StrandsSemantics.grouped(board, by: .group)

        XCTAssertEqual(groups.map(\.project),
                       [.tag1, .personal, .network, .viaConMe, .perseido, .unfiled])
        XCTAssertEqual(groups.map(\.title),
                       ["Tag1", "Personal", "Network", "Via Con Me", "Perseido", "No project"])
    }

    /// A group with nothing in it gets no heading. Five headings over one row each and
    /// one empty would be a board mostly made of furniture.
    func testAnEmptyGroupIsNotDrawn() {
        let groups = StrandsSemantics.grouped([strand("A", group: .tag1)], by: .group)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.project, .tag1)
    }

    /// **Server order is the tiebreak, under both lenses.** The bridge sorts by
    /// `updated` descending then title; a lens reorders, and within a tie it must not
    /// shuffle, because a board that reshuffled its tied rows on every redraw reads as
    /// the screen twitching.
    func testGroupingIsStableWithinAGroup() {
        let board = [strand("first", group: .tag1, updated: "2026-09-24"),
                     strand("second", group: .tag1, updated: "2026-09-24"),
                     strand("third", group: .tag1, updated: "2026-09-24")]
        let rows = StrandsSemantics.grouped(board, by: .group).first?.strands ?? []
        XCTAssertEqual(rows.map(\.slug), ["first", "second", "third"])
    }

    /// Dormant strands sink into one collapsed group at the bottom under BOTH lenses,
    /// and they are never filed under their project heading: work deliberately set down
    /// must not sit among the work that is moving.
    func testDormantStrandsSinkUnderBothLenses() {
        let board = [strand("Live", group: .tag1),
                     strand("Asleep", group: .tag1, state: .dormant)]

        for key in StrandsSortKey.allCases {
            let groups = StrandsSemantics.grouped(board, by: key)
            XCTAssertEqual(groups.last?.title, "Dormant", "under \(key.label)")
            XCTAssertEqual(groups.last?.strands.map(\.slug), ["Asleep"], "under \(key.label)")
            XCTAssertFalse(groups.dropLast().contains { $0.strands.contains { $0.slug == "Asleep" } },
                           "a dormant strand appears once, under \(key.label)")
        }
    }

    /// `Most recent` is one flat section in the order the server sent: the bridge
    /// already sorted by `updated` descending, and re-sorting it here would be a second
    /// answer to a question already answered.
    func testMostRecentKeepsServerOrder() {
        let board = [strand("newest", updated: "2026-09-24"),
                     strand("older", updated: "2026-09-01")]
        let groups = StrandsSemantics.grouped(board, by: .mostRecent)
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.title)
        XCTAssertEqual(groups.first?.strands.map(\.slug), ["newest", "older"])
    }

    // MARK: - What a row says

    /// ONE ROW, whole: the project, the title, where it stands, what runs next with its
    /// gate, the caption, and the age. This is what a screen reader hears and what the
    /// row draws, and it is asserted here because content a test cannot reach is content
    /// nobody checks.
    func testOneRowReadsAsOneSentence() {
        let argus = strand("Argus", group: .personal, updated: "2026-09-21",
                           now: "The kernel build is green.",
                           waiting: StrandWaiting(text: "you: create the empty repository",
                                                  jeremy: true),
                           next: StrandNext(id: "A1d",
                                            text: "Guest budget probe on the fixed kernel.",
                                            waitsOn: "provider key"))

        XCTAssertEqual(
            StrandsSemantics.rowAccessibilityLabel(argus, today: "2026-09-24"),
            "Project: Personal, Argus, The kernel build is green., "
            + "Next: A1d Guest budget probe on the fixed kernel. · waits on provider key, "
            + "Waiting on you, updated 3d ago")
    }

    /// The `Next:` line: the id leads because it is what a prompt is called, the gate
    /// follows the text because it qualifies the step rather than replacing it, and the
    /// separator is a MIDDLE DOT — no dash reaches a user facing string in this app.
    func testNextLine() {
        XCTAssertEqual(
            StrandsSemantics.nextLine(strand("A", next: StrandNext(id: "P3", text: "Ship it."))),
            "P3 Ship it.")
        XCTAssertEqual(
            StrandsSemantics.nextLine(strand("A", next: StrandNext(id: "P3", text: "Ship it.",
                                                                   waitsOn: "review"))),
            "P3 Ship it. · waits on review")
        XCTAssertEqual(
            StrandsSemantics.nextLine(strand("A", next: StrandNext(id: "", text: "Ship it."))),
            "Ship it.")
        XCTAssertNil(StrandsSemantics.nextLine(strand("A")),
                     "a strand with nothing queued says nothing about what is next")
        XCTAssertNil(StrandsSemantics.nextLine(strand("A", next: StrandNext(id: "", text: ""))))
    }

    /// No dash of any kind in what the board says. The row's separator, the caption and
    /// the empty state all go through here.
    func testNoUserFacingStringCarriesADash() {
        let strings = [StrandsWording.waitingOnYou,
                       StrandsListView.emptyTitle,
                       StrandsListView.emptyMessage,
                       StrandsListView.couldNotOpen("Argus"),
                       StrandRemoteNoteView.provenance,
                       StrandsSemantics.nextLine(strand("A", next: StrandNext(id: "P3",
                                                                              text: "Ship it.",
                                                                              waitsOn: "review")))!]
        for string in strings {
            XCTAssertFalse(string.contains("\u{2014}"), "em dash in: \(string)")
            XCTAssertFalse(string.contains("\u{2013}"), "en dash in: \(string)")
            XCTAssertFalse(string.contains("--"), "double hyphen in: \(string)")
        }
    }

    /// The age label, in the width of a label. A stamp that is not a plain ISO day, and
    /// one in the future, say NOTHING rather than a guess: the audit already has a
    /// finding for the first, and inventing an age would hide it.
    func testRelativeUpdated() {
        let today = "2026-09-24"
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-09-24", today: today), "today")
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-09-23", today: today), "1d")
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-09-11", today: today), "13d")
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-09-10", today: today), "2w")
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-08-24", today: today), "4w")
        XCTAssertNil(StrandsSemantics.relativeUpdated("2026-09-25", today: today))
        XCTAssertNil(StrandsSemantics.relativeUpdated("soon", today: today))
        XCTAssertNil(StrandsSemantics.relativeUpdated("", today: today))
        // Across a month and a leap year, because the day arithmetic is hand written.
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2026-08-31", today: "2026-09-01"), "1d")
        XCTAssertEqual(StrandsSemantics.relativeUpdated("2024-02-28", today: "2024-03-01"), "2d")
    }

    // MARK: - The model

    /// **The offline cache serves the last board.** Kill the bridge, reopen the app, and
    /// the board is still there behind its caption rather than a spinner that resolves
    /// into an error.
    func testCacheServesTheLastBoardWithTheBridgeUnreachable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-strands-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = SnapshotCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let body = Data("""
        { "generated_at": "2026-09-24T09:40:00+02:00",
          "strands": [ { "slug": "Argus", "title": "Argus", "group": "personal",
                         "state": "active", "updated": "2026-09-23" } ],
          "counts": { "active": 1, "waiting": 0, "dormant": 0 } }
        """.utf8)
        let fetched = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(cache.store(body, key: SnapshotCacheKey.strands,
                                  etag: "\"abc\"", fetchedAt: fetched))

        let model = StrandsModel(makeClient: { UnreachableStrandsClient() },
                                 now: { fetched.addingTimeInterval(600) },
                                 cache: cache)
        model.primeFromCache()

        XCTAssertEqual(model.snapshot?.strands.map(\.slug), ["Argus"])
        XCTAssertEqual(model.etag, "\"abc\"", "the cached tag makes the next GET conditional")
        XCTAssertTrue(model.isShowingCachedSnapshot)

        // The fetch that then fails must not take the board off the screen.
        await model.load()
        XCTAssertEqual(model.snapshot?.strands.map(\.slug), ["Argus"])
        XCTAssertTrue(model.isOffline)
        XCTAssertNotNil(model.stalenessLine)
        if case .content(let groups) = model.displayState {
            XCTAssertEqual(groups.first?.strands.first?.slug, "Argus")
        } else {
            XCTFail("a cached board still renders: \(model.displayState)")
        }
    }

    /// A board with nothing in it is an ANSWER: the bridge replied and had nothing to
    /// list. Never the offline state, which would blame the network for a true answer.
    func testAnEmptyBoardIsNotAnError() async {
        let model = StrandsModel(makeClient: { StubStrandsClient(snapshot: StrandsSnapshot()) })
        await model.load()
        XCTAssertEqual(model.displayState, .empty)
        XCTAssertFalse(model.isOffline)
    }

    /// The day every stamp is measured against is the BRIDGE's, because the stamps are
    /// the vault's and the vault's clock is the Studio's. A phone in another zone must
    /// not read a note touched this morning as a day old.
    func testReferenceDayComesFromTheBridgeWhenItSentOne() async {
        let snap = StrandsSnapshot(strands: [strand("A")],
                                   generatedAt: "2026-09-24T00:30:00+02:00")
        let model = StrandsModel(makeClient: { StubStrandsClient(snapshot: snap) },
                                 now: { Date(timeIntervalSince1970: 0) })
        await model.load()
        XCTAssertEqual(model.referenceDay, "2026-09-24")
    }

    /// With no stamp to read, this device's own day. `1970-01-01` is what the injected
    /// clock above makes that, which is the point: it is derived, not guessed.
    func testReferenceDayFallsBackToThisDevice() async {
        let model = StrandsModel(makeClient: { StubStrandsClient(snapshot: StrandsSnapshot()) },
                                 now: { Date(timeIntervalSince1970: 0) })
        await model.load()
        XCTAssertEqual(model.referenceDay, "1970-01-01")
    }
}

// MARK: - Fakes

private struct UnreachableStrandsClient: StrandsProviding {
    func getStrands(ifNoneMatch: String?) async throws -> StrandsFetchResult {
        throw JesseError.cannotConnect("studio.local")
    }
    func getStrand(slug: String) async throws -> StrandDetail {
        throw JesseError.cannotConnect("studio.local")
    }
}

private struct StubStrandsClient: StrandsProviding {
    let snapshot: StrandsSnapshot
    func getStrands(ifNoneMatch: String?) async throws -> StrandsFetchResult {
        .snapshot(snapshot)
    }
    func getStrand(slug: String) async throws -> StrandDetail {
        StrandDetail(markdown: "# \(slug)")
    }
}
