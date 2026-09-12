import XCTest
@testable import JesseNetworking

/// Live usage and quota (App 1.0 (134), bridge 0.137.0): the pure presentation rules, the wire
/// decode against the bridge's own shapes, the store, and the chip's one warning glyph.
final class QuotaTests: XCTestCase {

    /// 2026-09-12T09:45:55Z, the morning the live bodies were captured.
    private let now: Int64 = 1_789_205_155_000

    private func claude(fetchedAgo secs: Int64 = 5, ttl: Int? = 120,
                        error: String? = nil) -> QuotaScope {
        QuotaScope(id: "claude-subscription", label: "Claude subscription",
                   models: ["opus", "fable"],
                   windows: [QuotaWindow(id: "five_hour", label: "5 hours", usedPercent: 23),
                             QuotaWindow(id: "seven_day", label: "7 days", usedPercent: 41)],
                   plan: "max", fetchedAtMs: now - secs * 1000, error: error, ttlSecs: ttl)
    }

    // MARK: - The menu's usage line

    func testWindowsRenderAsShortLabelAndPercent() {
        XCTAssertEqual(QuotaPresentation.usageLine(for: claude(), nowMs: now), "5h 23% · week 41%")
        let codex = QuotaScope(id: "codex-chatgpt",
                               windows: [QuotaWindow(id: "primary", label: "7 days", usedPercent: 0),
                                         QuotaWindow(id: "secondary", label: "45 min", usedPercent: 12.6)],
                               fetchedAtMs: now)
        XCTAssertEqual(QuotaPresentation.usageLine(for: codex, nowMs: now), "week 0% · 45m 13%")
    }

    func testASpendAccountRendersItsMonth() {
        let quiet = QuotaScope(id: "fireworks", spend: QuotaSpend(monthToDateUsd: 0), fetchedAtMs: now)
        XCTAssertEqual(QuotaPresentation.usageLine(for: quiet, nowMs: now), "$0.00 this month")
        let estimated = QuotaScope(id: "fireworks",
                                   spend: QuotaSpend(monthToDateUsd: 1.752, estimated: true),
                                   fetchedAtMs: now)
        XCTAssertEqual(QuotaPresentation.usageLine(for: estimated, nowMs: now),
                       "about $1.75 this month")
    }

    func testASnapshotOlderThanThreeTTLsSaysStale() {
        XCTAssertEqual(QuotaPresentation.usageLine(for: claude(fetchedAgo: 360), nowMs: now),
                       "5h 23% · week 41%", "exactly three TTLs is not yet stale")
        XCTAssertEqual(QuotaPresentation.usageLine(for: claude(fetchedAgo: 361), nowMs: now),
                       "5h 23% · week 41% · stale")
        // A bridge that does not report its TTL: Fireworks' default is 600 s.
        let fw = QuotaScope(id: "fireworks", spend: QuotaSpend(monthToDateUsd: 2),
                            fetchedAtMs: now - 1_801_000)
        XCTAssertEqual(QuotaPresentation.usageLine(for: fw, nowMs: now), "$2.00 this month · stale")
    }

    func testAnErrorShowsOnlyWhenThereIsNothingElse() {
        let none = QuotaScope(id: "fireworks", fetchedAtMs: now,
                              error: "spend not configured (set fireworks_account_id)")
        XCTAssertEqual(QuotaPresentation.usageLine(for: none, nowMs: now),
                       "spend not configured (set fireworks_account_id)")
        XCTAssertEqual(QuotaPresentation.usageLine(
            for: claude(error: "login expired, refreshes on the next Claude turn"), nowMs: now),
                       "5h 23% · week 41%", "last good data wins the menu line")
    }

    func testNoAccountRendersNothing() {
        XCTAssertNil(QuotaPresentation.usageLine(for: nil, nowMs: now))
        XCTAssertNil(QuotaPresentation.usageLine(for: QuotaScope(id: "codex-chatgpt"), nowMs: now))
    }

    // MARK: - The Settings card's clock strings

    func testTheResetCountdown() {
        let at = { (secs: Int64) in QuotaPresentation.resetCountdown(self.now + secs * 1000, nowMs: self.now) }
        XCTAssertEqual(at(2 * 3600 + 10 * 60), "resets in 2h 10m")
        XCTAssertEqual(at(30), "resets in 1m", "under a minute rounds up, never says 0m")
        XCTAssertEqual(at(26 * 3600), "resets in 1d 2h")
        XCTAssertEqual(at(-5), "resets now")
        XCTAssertNil(QuotaPresentation.resetCountdown(nil, nowMs: now))
    }

    func testUpdatedAgo() {
        XCTAssertEqual(QuotaPresentation.updatedAgo(now, nowMs: now), "updated 0s ago")
        XCTAssertEqual(QuotaPresentation.updatedAgo(now - 90_000, nowMs: now), "updated 1m ago")
        XCTAssertEqual(QuotaPresentation.updatedAgo(now - 7_200_000, nowMs: now), "updated 2h ago")
        XCTAssertNil(QuotaPresentation.updatedAgo(0, nowMs: now), "never fetched")
    }

    func testNoPresentedStringContainsADash() {
        let dashes = CharacterSet(charactersIn: "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}")
        let strings: [String?] = [
            QuotaPresentation.usageLine(for: claude(fetchedAgo: 999), nowMs: now),
            QuotaPresentation.usageLine(for: QuotaScope(id: "fireworks",
                                                        spend: QuotaSpend(monthToDateUsd: 3, estimated: true)),
                                        nowMs: now),
            QuotaPresentation.resetCountdown(now + 99_000_000, nowMs: now),
            QuotaPresentation.updatedAgo(now - 5_000, nowMs: now),
            QuotaPresentation.windowLine(QuotaWindow(id: "extra_usage", label: "extra usage", usedPercent: 0)),
        ]
        for s in strings.compactMap({ $0 }) {
            XCTAssertNil(s.rangeOfCharacter(from: dashes), s)
        }
    }

    // MARK: - Wire

    /// The bridge's own `GET /jesse/usage` shape (the Claude entry from the 2026-09-12 live
    /// body, the Fireworks one as an account with no id reports itself).
    func testUsageDecodesFromTheBridgeShape() throws {
        let json = """
        {"scopes": [
          {"id": "claude-subscription", "label": "Claude subscription", "models": ["opus", "fable"],
           "windows": [{"id": "five_hour", "label": "5 hours", "used_percent": 8.0,
                        "resets_at_ms": 1789212600965, "status": null},
                       {"id": "seven_day", "label": "7 days", "used_percent": 27,
                        "resets_at_ms": 1789354800965, "status": "allowed"}],
           "spend": null, "plan": "max", "fetched_at_ms": 1789205155000, "source": "fetched",
           "error": null, "warning": false, "ttl_secs": 120},
          {"id": "fireworks", "label": "Fireworks", "models": ["glm"], "windows": [],
           "spend": null, "plan": null, "fetched_at_ms": 1789205155000, "source": "fetched",
           "error": "spend not configured (set fireworks_account_id)", "warning": false,
           "ttl_secs": 600, "a_field_from_the_future": true}
        ]}
        """
        let usage = try JSONDecoder().decode(UsageState.self, from: Data(json.utf8))
        XCTAssertEqual(usage.scopes.map(\.id), ["claude-subscription", "fireworks"])
        let c = usage.scopes[0]
        XCTAssertEqual(c.windows.map(\.usedPercent), [8, 27], "an integer percentage decodes too")
        XCTAssertEqual(c.windows[1].status, "allowed")
        XCTAssertEqual(c.ttlSecs, 120)
        XCTAssertEqual(QuotaPresentation.usageLine(for: c, nowMs: 1_789_205_160_000), "5h 8% · week 27%")
        XCTAssertEqual(usage.scopes[1].error, "spend not configured (set fireworks_account_id)")
    }

    func testAScopeMissingItsNewerFieldsStillDecodes() throws {
        let usage = try JSONDecoder().decode(
            UsageState.self, from: Data(#"{"scopes": [{"id": "codex-chatgpt"}]}"#.utf8))
        XCTAssertEqual(usage.scopes.first, QuotaScope(id: "codex-chatgpt"))
        XCTAssertEqual(try JSONDecoder().decode(UsageState.self, from: Data("{}".utf8)).scopes, [])
    }

    func testModelInfoDecodesItsUsageScopeAndAnOlderBridgeLeavesItNil() throws {
        let row = """
        {"id": "glm", "label": "GLM 5.3", "kind": "hosted", "available": true,
         "writes_allowed": true, "usage_scope": "fireworks"}
        """
        XCTAssertEqual(try JSONDecoder().decode(ModelInfo.self, from: Data(row.utf8)).usageScope,
                       "fireworks")
        let old = """
        {"id": "glm", "label": "GLM 5.3", "kind": "hosted", "available": true, "writes_allowed": true}
        """
        XCTAssertNil(try JSONDecoder().decode(ModelInfo.self, from: Data(old.utf8)).usageScope)
        let local = """
        {"id": "local", "label": "Local", "kind": "local", "available": true,
         "writes_allowed": true, "usage_scope": null}
        """
        XCTAssertNil(try JSONDecoder().decode(ModelInfo.self, from: Data(local.utf8)).usageScope)
    }

    func testAModelFindsItsAccountByUsageScopeOrByMembership() {
        let usage = UsageState(scopes: [claude()])
        let tagged = ModelInfo(id: "opus", label: "Opus", kind: "ambient", available: true,
                               writesAllowed: true, usageScope: "claude-subscription")
        XCTAssertEqual(usage.scope(for: tagged)?.id, "claude-subscription")
        let untagged = ModelInfo(id: "fable", label: "Fable", kind: "subscription",
                                 available: true, writesAllowed: true)
        XCTAssertEqual(usage.scope(for: untagged)?.id, "claude-subscription", "listed in models")
        let local = ModelInfo(id: "local", label: "Local", kind: "local", available: true,
                              writesAllowed: true)
        XCTAssertNil(usage.scope(for: local))
    }

    // MARK: - Provenance

    private let provenanceBase = """
    "route": "hosted", "model": "opus", "cost_usd": 0.01, "badge": "[opus · $0.0100]",
    "flags": {"hosted_verify": false, "verify_queued": false, "citations_unverified": false}
    """

    func testProvenanceDecodesQuotaWhenPresentAndIsUnchangedWithout() throws {
        let without = try JSONDecoder().decode(
            JesseProvenance.self, from: Data("{\(provenanceBase)}".utf8))
        XCTAssertNil(without.quota)
        XCTAssertFalse(without.isUsageWarning)
        XCTAssertFalse(without.accessibilityText.contains("usage near limit"))

        let with = try JSONDecoder().decode(JesseProvenance.self, from: Data("""
        {\(provenanceBase), "quota": {"id": "claude-subscription", "label": "Claude subscription",
          "models": ["opus"], "windows": [{"id": "five_hour", "label": "5 hours",
          "used_percent": 95.0, "resets_at_ms": null, "status": "allowed_warning"}],
          "spend": null, "plan": "max", "fetched_at_ms": 5, "source": "turn", "error": null,
          "warning": true, "ttl_secs": 120}}
        """.utf8))
        XCTAssertEqual(with.quota?.windows.first?.usedPercent, 95)
        XCTAssertEqual(with.quota?.source, "turn")
        XCTAssertTrue(with.isUsageWarning)
        XCTAssertTrue(with.accessibilityText.hasSuffix("usage near limit"), with.accessibilityText)
        // The persisted form round trips, so the glyph survives a relaunch.
        XCTAssertEqual(JesseProvenance.from(json: with.jsonString), with)
    }

    func testAnUnreadableQuotaCostsTheQuotaAndNeverTheChip() throws {
        let p = try JSONDecoder().decode(
            JesseProvenance.self, from: Data(#"{\#(provenanceBase), "quota": 5}"#.utf8))
        XCTAssertNil(p.quota)
        XCTAssertEqual(p.badge, "[opus · $0.0100]")
    }

    // MARK: - The store and the one shot load

    @MainActor
    func testATurnReplacesItsAccountAndLeavesTheOthers() {
        let fireworks = QuotaScope(id: "fireworks", spend: QuotaSpend(monthToDateUsd: 1))
        let store = UsageStore(state: UsageState(scopes: [claude(), fireworks]))
        let fromTurn = QuotaScope(id: "claude-subscription",
                                  windows: [QuotaWindow(id: "five_hour", label: "5 hours", usedPercent: 91)],
                                  fetchedAtMs: now, source: "turn", warning: true)
        store.apply(fromTurn)
        XCTAssertEqual(store.state?.scopes, [fromTurn, fireworks], "replaced in place")
        store.apply(nil)
        XCTAssertEqual(store.state?.scopes.count, 2, "nil is a no-op")
        let empty = UsageStore()
        empty.apply(fireworks)
        XCTAssertEqual(empty.state?.scopes, [fireworks], "a first turn seeds the store")
    }

    @MainActor
    func testTheUsageLoadIsTheSameBoundedBurstAndAnUnpairedAppDoesNothing() async {
        var attempts = 0
        var waited: [TimeInterval] = []
        let none = await loadUsage(isConfigured: true,
                                   fetch: { attempts += 1; return nil },
                                   sleep: { waited.append($0) })
        XCTAssertNil(none)
        XCTAssertEqual(attempts, ModelListRetry.maxAttempts)
        XCTAssertEqual(waited, ModelListRetry.delays)

        attempts = 0
        let unpaired = await loadUsage(isConfigured: false,
                                       fetch: { attempts += 1; return UsageState(scopes: []) },
                                       sleep: { _ in XCTFail("an unpaired app never waits") })
        XCTAssertNil(unpaired)
        XCTAssertEqual(attempts, 0)

        let first = await loadUsage(isConfigured: true,
                                    fetch: { UsageState(scopes: [self.claude()]) },
                                    sleep: { _ in XCTFail("no wait after a success") })
        XCTAssertEqual(first?.scopes.first?.id, "claude-subscription")
    }
}
