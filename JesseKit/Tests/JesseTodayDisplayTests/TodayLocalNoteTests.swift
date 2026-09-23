import XCTest
@testable import JesseTodayDisplay
import JesseNetworking
import JesseVault

// THE OFFLINE HALF OF THE DETAIL SHEET: which note an item would open with no bridge in
// reach, and what the sheet shows when it finds one.
//
// The resolution itself is JesseVault's and is tested there over a real folder. What is
// only true HERE is the decision layer: where an item's targets come from, when the local
// copy is tried, and that a brief is never invented for it.

@MainActor
final class TodayLocalNoteTests: XCTestCase {

    // MARK: - Fakes

    /// A client that always fails the way an unreachable bridge fails.
    private final class UnreachableClient: TodayDetailProviding, @unchecked Sendable {
        private(set) var calls = 0
        func getItemDetail(id: String, ifNoneMatch: String?) async throws -> TodayDetailResult {
            calls += 1
            throw JesseError.notConfigured
        }
    }

    private final class WorkingClient: TodayDetailProviding, @unchecked Sendable {
        let note: TodayItemDetail
        private(set) var calls = 0
        init(note: TodayItemDetail) { self.note = note }
        func getItemDetail(id: String, ifNoneMatch: String?) async throws -> TodayDetailResult {
            calls += 1
            return .detail(note)
        }
    }

    /// A vault that answers for the targets it was given and nothing else — "a fake folder",
    /// with no filesystem in it at all.
    private final class FakeVault: TodayLocalNoteProviding, @unchecked Sendable {
        var notes: [String: LocalVaultNote] = [:]
        private(set) var asked: [[String]] = []

        func localNote(forTargets targets: [String]) async -> LocalVaultNote? {
            asked.append(targets)
            for target in targets {
                if let note = notes[target] { return note }
            }
            return nil
        }
    }

    private let kiln = LocalVaultNote(path: "Workshop/Kiln-Rebuild.md",
                                      target: "Workshop/Kiln-Rebuild",
                                      markdown: "# Kiln notes\n\nThe floor cracked.\n",
                                      modified: Date(timeIntervalSince1970: 1_780_000_000))

    private func item(links: [TodayLink] = [], text: String = "", lead: String = "")
        -> TodayItem {
        TodayItem(id: "aaaaaaaaaaaa", lead: lead, text: text, links: links,
                  sectionName: "Do Now")
    }

    // MARK: - Where the targets come from

    /// THE WIRE ITEM CARRIES THEM. `TodayItem.links` is the bridge's own `extract_links`
    /// output, so the normal path needs no parsing at all — and a URL among them is not a
    /// note.
    func testTargetsComeFromTheWireItemsOwnLinks() {
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki"),
                                   TodayLink(target: "https://tag1.com", kind: "url"),
                                   TodayLink(target: "Suppliers/Terrasole.md", kind: "wiki")],
                           text: "- [ ] Order the bricks")

        XCTAssertEqual(TodayLocalTargets.targets(for: subject),
                       ["Workshop/Kiln-Rebuild", "Suppliers/Terrasole"],
                       "wiki links only, normalized, in the item's own order")
    }

    /// THE FALLBACK READS `text`, NOT `lead`. The bridge strips markdown to build a lead, so
    /// `[[Workshop/Kiln-Rebuild|the kiln]]` becomes the words "the kiln" with the target
    /// gone: a fallback that only parsed the lead would find nothing on exactly the items
    /// that have links.
    func testWithNoWireLinksTheTargetsAreParsedOutOfTheRawText() {
        let subject = item(text: "- [ ] Order the bricks from [[Suppliers/Terrasole]]",
                           lead: "Order the bricks from Terrasole")

        XCTAssertEqual(TodayLocalTargets.targets(for: subject), ["Suppliers/Terrasole"])
    }

    /// A lead that DOES still carry brackets is parsed too, for a hand-written line the
    /// bridge never stripped.
    func testAWikiLinkLeftInTheLeadIsStillFound() {
        let subject = item(text: "", lead: "Ask [[People/Marta Ruggeri|Marta]]")
        XCTAssertEqual(TodayLocalTargets.targets(for: subject), ["People/Marta Ruggeri"])
    }

    func testAnItemWithNoLinksAtAllHasNoTargets() {
        XCTAssertEqual(TodayLocalTargets.targets(for: item(text: "- [ ] Buy milk")), [])
    }

    // MARK: - When the local copy is used

    /// ALREADY READ-ONLY: the day screen has just told the user it cannot reach the bridge,
    /// so opening an item goes straight to the local copy and makes NO request at all rather
    /// than spending a second timeout proving the same thing.
    func testAReadOnlyDayOpensTheLocalCopyWithoutCallingTheBridge() async {
        let client = UnreachableClient()
        let vault = FakeVault()
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let model = TodayDetailModel(makeClient: { client }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject, isReadOnly: true)

        XCTAssertEqual(client.calls, 0, "no request is made when the screen knows there is no bridge")
        XCTAssertEqual(model.state, .localCopy(kiln))
        XCTAssertEqual(model.localNote?.path, "Workshop/Kiln-Rebuild.md")
        XCTAssertTrue(model.isOffline)
        XCTAssertNil(model.brief, "nobody writes a brief offline, and none is invented")
        XCTAssertNil(model.note, "the wire note is nil: these two are never both set")
    }

    /// THE OTHER WAY IN: the day looked fine, the request failed, nothing was cached. The
    /// local copy is tried BEFORE `.unavailable` is published, so the screen never says "can't
    /// reach the bridge" about a note this device is holding.
    func testAFailedRequestWithNothingCachedFallsBackToTheLocalCopy() async {
        let client = UnreachableClient()
        let vault = FakeVault()
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let model = TodayDetailModel(makeClient: { client }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject)

        XCTAssertEqual(client.calls, 1, "the bridge was tried, because nothing said it was down")
        XCTAssertEqual(model.state, .localCopy(kiln))
        XCTAssertNil(model.lastErrorMessage, "a note was found, so there is nothing to apologize for")
    }

    /// The links are followed in the ITEM's order: the first one is the one the bridge would
    /// have resolved, and the offline copy must follow the same link or it is a different
    /// note.
    func testTheFirstResolvableTargetWins() async {
        let vault = FakeVault()
        vault.notes["Suppliers/Terrasole"] = LocalVaultNote(path: "Suppliers/Terrasole.md",
                                                           target: "Suppliers/Terrasole",
                                                           markdown: "# Terrasole\n")
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let model = TodayDetailModel(makeClient: { UnreachableClient() }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki"),
                                   TodayLink(target: "Suppliers/Terrasole", kind: "wiki")])

        await model.load(item: subject, isReadOnly: true)

        XCTAssertEqual(model.localNote?.path, "Workshop/Kiln-Rebuild.md")
        XCTAssertEqual(vault.asked.first, ["Workshop/Kiln-Rebuild", "Suppliers/Terrasole"])
    }

    /// A link the local copy cannot resolve leaves the screen exactly where it was before
    /// this feature existed: the honest "can't reach the bridge".
    func testAnUnresolvedTargetStillEndsInTheUnavailableState() async {
        let model = TodayDetailModel(makeClient: { UnreachableClient() },
                                    localNotes: FakeVault())
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject, isReadOnly: true)

        guard case .unavailable = model.state else {
            return XCTFail("expected .unavailable, got \(model.state)")
        }
        XCTAssertNotNil(model.lastErrorMessage)
    }

    /// NO FOLDER ON THIS DEVICE — no provider passed at all — and the behaviour is byte for
    /// byte what it was before: the bridge, and only the bridge.
    func testWithNoLocalVaultTheBehaviourIsUnchanged() async {
        let client = UnreachableClient()
        let model = TodayDetailModel(makeClient: { client })
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject, isReadOnly: true)

        XCTAssertEqual(client.calls, 1)
        guard case .unavailable = model.state else {
            return XCTFail("expected .unavailable, got \(model.state)")
        }
        XCTAssertNil(model.localNote)
    }

    /// An item with no links is not offered a local copy at all: there is nothing to resolve,
    /// and the vault is never asked.
    func testAnItemWithNoLinksNeverAsksTheVault() async {
        let vault = FakeVault()
        let model = TodayDetailModel(makeClient: { UnreachableClient() }, localNotes: vault)

        await model.load(item: item(text: "- [ ] Buy milk"), isReadOnly: true)

        XCTAssertTrue(vault.asked.isEmpty)
    }

    /// THE BRIDGE WINS WHEN IT ANSWERS. With a reachable bridge the local copy is never
    /// consulted — it is a fallback, not a cache, and the bridge's note comes with a brief.
    func testAReachableBridgeIsAlwaysPreferred() async {
        let note = TodayItemDetail(id: "aaaaaaaaaaaa", path: "Workshop/Kiln-Rebuild.md",
                                   target: "Workshop/Kiln-Rebuild",
                                   markdown: "# From the bridge\n", etag: "\"n1\"")
        let client = WorkingClient(note: note)
        let vault = FakeVault()
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let model = TodayDetailModel(makeClient: { client }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject)

        XCTAssertEqual(model.state, .loaded(note))
        XCTAssertTrue(vault.asked.isEmpty, "the local copy is a fallback, never a shortcut")
        XCTAssertFalse(model.isOffline)
    }

    /// Coming back online replaces the offline copy with the bridge's own answer, which is
    /// what step 3 of the device checklist walks through by hand.
    func testComingBackOnlineReplacesTheOfflineCopy() async {
        let vault = FakeVault()
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let offline = TodayDetailModel(makeClient: { UnreachableClient() }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])
        await offline.load(item: subject, isReadOnly: true)
        XCTAssertEqual(offline.state, .localCopy(kiln))

        // The same model, now with a bridge that answers.
        let note = TodayItemDetail(id: "aaaaaaaaaaaa", path: "Workshop/Kiln-Rebuild.md",
                                   markdown: "# From the bridge\n", etag: "\"n1\"")
        let client = WorkingClient(note: note)
        let online = TodayDetailModel(makeClient: { client }, localNotes: vault)
        await online.load(item: subject)

        XCTAssertEqual(online.state, .loaded(note))
        XCTAssertFalse(online.isOffline)
    }

    /// A cached note from an earlier online read still beats the local copy: it is the
    /// bridge's own answer, brief and all, and it was good a minute ago.
    func testACachedNoteIsPreferredToTheLocalCopy() async {
        let note = TodayItemDetail(id: "aaaaaaaaaaaa", path: "Workshop/Kiln-Rebuild.md",
                                   markdown: "# From the bridge\n", etag: "\"n1\"")
        final class ThenFails: TodayDetailProviding, @unchecked Sendable {
            let note: TodayItemDetail
            var calls = 0
            init(note: TodayItemDetail) { self.note = note }
            func getItemDetail(id: String, ifNoneMatch: String?) async throws
                -> TodayDetailResult {
                calls += 1
                if calls == 1 { return .detail(note) }
                throw JesseError.notConfigured
            }
        }
        let client = ThenFails(note: note)
        let vault = FakeVault()
        vault.notes["Workshop/Kiln-Rebuild"] = kiln
        let model = TodayDetailModel(makeClient: { client }, localNotes: vault)
        let subject = item(links: [TodayLink(target: "Workshop/Kiln-Rebuild", kind: "wiki")])

        await model.load(item: subject)
        await model.load(item: subject, force: true)

        XCTAssertEqual(model.state, .loaded(note))
        XCTAssertTrue(model.isOffline, "and it is flagged as possibly stale, as before")
        XCTAssertTrue(vault.asked.isEmpty)
    }

    // MARK: - What the sheet says about it

    /// The badge names the file's OWN modification time. A synced folder can be hours behind
    /// the Studio, and "offline copy" alone does not tell a reader how old what they are
    /// holding is.
    func testTheBadgeNamesWhenTheLocalCopyWasLastChanged() {
        let badge = TodayDetailView.localCopyBadge(Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(badge.contains("Offline copy"))
        XCTAssertTrue(badge.contains("2026"))
        XCTAssertTrue(TodayDetailView.localCopyBadge(nil).contains("Offline copy"))
    }

    /// The offline copy is cut at the same 64 KB the bridge cuts a detail note at, so a
    /// reader is not told a different story about the same file depending on the network.
    func testTheOfflineCopyUsesTheSameCeilingAsTheBridge() {
        XCTAssertEqual(LocalVaultNote.byteLimit, 64 * 1024)
        let long = String(repeating: "brick ", count: 20_000)
        let (cut, truncated) = VaultNoteDocument.truncate(long,
                                                          byteLimit: LocalVaultNote.byteLimit)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(cut.utf8.count, LocalVaultNote.byteLimit)
    }
}
