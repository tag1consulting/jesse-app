import XCTest
import SwiftUI
import JesseAsk
@testable import JesseOps

// "Ask about this" on the OPS screens — the serializers, the identities, and the budget.
//
// What these pin is the set of claims the feature rests on:
//
//  * EVERY CARD ANSWERS. A press on any card produces a snapshot that carries the values
//    that card exists to show — a version, a state, a free-space figure. A serializer that
//    silently produced an empty block would look like a working gesture and answer nothing.
//  * THE SNAPSHOT IS THE SCREEN, with one deliberate exception, and the exception is the
//    half Jeremy asked for by name: the Deploy card FOLDS most undeployed releases away
//    behind a disclosure group, and the snapshot carries all of them, because the question
//    is "what would a deploy bring in".
//  * STALENESS TRAVELS. A cached view of `origin/main` says so inside the snapshot, not
//    merely in the card's title. A cached answer presented as a current one is the one way
//    this snapshot could mislead about the machine.
//  * SILENT TRUNCATION READS AS COMPLETENESS. Both losses are stated: what the app capped,
//    and what the sentinel dropped before the app ever saw the document.
//  * IDENTITY. Ops keys live in their own namespace, differ per subject, and are stable
//    across two presses in the same day — which is what "resume that conversation instead
//    of starting another" is decided on.

final class OpsAskTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed instant, so every assertion below is about the serializers rather than about
    /// what time the test ran. 2026-09-10 14:32 UTC.
    private let reading = OpsAskReading(taken: Date(timeIntervalSince1970: 1_789_050_720),
                                        zone: TimeZone(identifier: "UTC")!)

    private func healthy() throws -> SentinelStatusDocument {
        try SentinelStatusDocument.decode(Data(OpsDocumentDecodeTests.healthyStatus.utf8))
    }

    private func degraded() throws -> SentinelStatusDocument {
        try SentinelStatusDocument.decode(Data(OpsDocumentDecodeTests.degradedStatus.utf8))
    }

    private func withReleases() throws -> DeployStatusDocument {
        try DeployStatusDocument.decode(Data(DeployReleasesTests.withReleases.utf8))
    }

    /// A deploy card with more undeployed releases than the card shows expanded, so the
    /// fold is real, plus a stale `origin/main` view and a truncated tail.
    private func manyReleases(stale: Bool = false, truncated: Int = 4) throws
        -> DeployStatusDocument {
        let blocks = (0..<6).map { i in
            """
            {"sha": "\(String(repeating: String(i), count: 40))",
             "version": "bridge 0.1\(i)0.0", "title": "Release number \(i)",
             "date_ms": 175660000000\(i), "lines": ["It changed thing \(i)."], "more": \(i)}
            """
        }.joined(separator: ",\n")
        let staleKeys = stale
            ? #", "stale": true, "stale_reason": "the GitHub API refused the last two reads""#
            : ""
        let json = """
        {
          "deploy": null,
          "running": {"version": "0.100.0", "sha": "\(String(repeating: "a", count: 40))"},
          "origin_main": {"sha": "\(String(repeating: "9", count: 40))",
                          "version": "0.150.0", "ci": "green",
                          "ci_detail": "run 42 passed", "checked_ms": 1756600000000\(staleKeys)},
          "releases": {
            "deployed": {"sha": "\(String(repeating: "a", count: 40))",
                         "version": "bridge 0.100.0", "title": "What is running",
                         "date_ms": 1756500000000, "lines": [], "more": 0},
            "undeployed": [\(blocks)],
            "truncated": \(truncated),
            "reason": null
          }
        }
        """
        return try DeployStatusDocument.decode(Data(json.utf8))
    }

    // MARK: - Every card answers

    /// One assertion per card: the snapshot is non-empty AND carries the value that card
    /// exists to show. A card that serialized to a heading and nothing else would pass a
    /// bare "not empty" check and answer no question.
    func testEveryCardSerializesTheValuesItExistsToCarry() throws {
        let status = try healthy()
        let cases: [(String, AskContext, [String])] = [
            ("bridge", OpsAsk.bridgeCard(status, reading: reading),
             ["Reachability", "0.94.0", "12 ms", "Europe/Rome", "Drift entries: 1"]),
            ("services", OpsAsk.servicesCard(status, reading: reading),
             ["launchd", "bridge", "running", "pid 15818", "autocommit", "not running"]),
            ("tailscale", OpsAsk.tailscaleCard(status, reading: reading),
             ["Online: yes", "studio.tailnet.ts.net.", "100.64.0.1"]),
            ("disk", OpsAsk.diskCard(status, reading: reading),
             ["/Users/you/vault", "free of", "Artifacts", "42 files"]),
            ("git", OpsAsk.gitCard(status, reading: reading),
             ["Branch: main", "Ahead / behind: 0 / ?", "clean", "autocommit: 3 files"]),
            ("qmd", OpsAsk.qmdCard(status, reading: reading), ["Index", "v22.14.0"]),
            ("watchdog", OpsAsk.watchdogCard(status, reading: reading),
             ["Last tick", "Kickstarts (last hour): 2", "Sentinel: 0.94.0"]),
            ("ledger", OpsAsk.ledgerSection(status.ledgerRows, reading: reading),
             ["morning", "fired", "Segmentation fault: 11"]),
            ("deploy", OpsAsk.deployCard(try withReleases(), reading: reading),
             ["Running: 0.106.0", "origin/main: 0.107.0", "CI green"]),
        ]
        for (name, context, expected) in cases {
            let snapshot = context.snapshotText
            XCTAssertFalse(snapshot.isEmpty, "\(name) serialized to nothing")
            for needle in expected {
                XCTAssertTrue(snapshot.contains(needle),
                              "\(name) snapshot is missing \"\(needle)\":\n\(snapshot)")
            }
        }
    }

    /// A DEGRADED document is the reading someone actually opens this screen for, and the
    /// three states have to stay three: `unknown` is not `failed`, and a probe that did not
    /// finish says so rather than reporting a cheerful default.
    func testADegradedDocumentSerializesUnknownAsUnknownRatherThanFailed() throws {
        let status = try degraded()
        let tailscale = OpsAsk.tailscaleCard(status, reading: reading).snapshotText
        XCTAssertTrue(tailscale.contains("unknown"))
        XCTAssertTrue(tailscale.contains("tailscale probe did not finish within 5s"))
        XCTAssertFalse(tailscale.contains("failed"), "grey is not a shade of red")

        let disk = OpsAsk.diskCard(status, reading: reading).snapshotText
        XCTAssertTrue(disk.contains("failed"))
        XCTAssertTrue(disk.contains("under the 5 GB floor"))
        XCTAssertTrue(disk.contains("entry ceiling"),
                      "a partial artifact walk must say its size is a floor")

        // The line that matters most when it is set.
        let watchdog = OpsAsk.watchdogCard(status, reading: reading).snapshotText
        XCTAssertTrue(watchdog.contains("GAVE UP"))
        XCTAssertTrue(watchdog.contains("nothing is trying to restart the bridge any more"))
        XCTAssertTrue(watchdog.contains("connection refused"))
    }

    /// A launchd job that never exited is not one that exited cleanly. The screen is careful
    /// never to print "last exit 0" for it, and so is the snapshot.
    func testANeverExitedServiceIsNotReportedAsACleanExit() throws {
        let rows = try healthy().serviceRows
        let bridge = OpsAsk.serviceRow(rows[0], reading: reading).snapshotText
        XCTAssertTrue(bridge.contains("running · pid 15818 · 7 runs"))
        XCTAssertFalse(bridge.contains("last exit"), "`(never exited)` must not read as 0")
        let autocommit = OpsAsk.serviceRow(rows[1], reading: reading).snapshotText
        XCTAssertTrue(autocommit.contains("last exit 1"))
    }

    // MARK: - The page

    /// COMPOSITION: the page contains every card's block. That is what makes the toolbar's
    /// one entry equivalent to pressing each card in turn, and what stops the two scopes
    /// telling two stories about the same machine.
    func testThePageContainsEveryCardsBlock() throws {
        let status = try healthy()
        let deploy = try withReleases()
        let page = OpsAsk.page(status: status, deploy: deploy, refreshError: nil,
                               isSentinelPaired: true, verbs: [.reloadEnv, .unlockGit],
                               lastVerb: nil, isRunningVerb: false, reading: reading)
        let snapshot = page.snapshotText
        for heading in ["Bridge", "Services", "Tailscale", "Disk", "Git", "QMD",
                        "Watchdog", "Actions", "Ledger", "Deploy"] {
            XCTAssertTrue(snapshot.contains(heading), "the page is missing \(heading)")
        }
        // And the identifiers a chat can dig with, as identifiers rather than instructions.
        XCTAssertTrue(snapshot.contains("running sha"))
        XCTAssertTrue(snapshot.contains("origin/main sha"))
    }

    /// A FAILED REFRESH never silently becomes a current reading. The screen keeps the last
    /// loaded document behind an error line, so the snapshot has to say which it is.
    func testThePageSaysWhenTheLastRefreshFailed() throws {
        let page = OpsAsk.page(status: try healthy(), deploy: nil,
                               refreshError: "sentinel at studio:8790: timed out",
                               isSentinelPaired: true, verbs: [], lastVerb: nil,
                               isRunningVerb: false, reading: reading)
        let snapshot = page.snapshotText
        XCTAssertTrue(snapshot.contains("The last refresh failed"))
        XCTAssertTrue(snapshot.contains("timed out"))
        XCTAssertTrue(snapshot.contains("from an earlier, successful read"))
    }

    /// With no sentinel paired the screen shows a call to action and no cards at all, and
    /// the snapshot says so rather than presenting an empty machine as a healthy one.
    func testThePageSaysWhenNoSentinelIsPaired() {
        let page = OpsAsk.page(status: nil, deploy: nil, refreshError: nil,
                               isSentinelPaired: false, verbs: [], lastVerb: nil,
                               isRunningVerb: false, reading: reading)
        XCTAssertTrue(page.snapshotText.contains("No sentinel is paired"))
    }

    // MARK: - The deploy question

    /// THE HALF THIS FEATURE EXISTS FOR. The card shows three undeployed releases expanded
    /// and folds the rest away; the snapshot carries every one of them, and states what the
    /// SENTINEL dropped before the document ever reached the app.
    @MainActor
    func testTheDeploySnapshotCarriesTheReleasesTheCardFoldedAway() throws {
        let doc = try manyReleases()
        // Read on the main actor and compared as a local: `expandedReleases` belongs to the
        // view, and an XCTAssert autoclosure is nonisolated.
        let expanded = OpsView.expandedReleases
        XCTAssertGreaterThan(try XCTUnwrap(doc.releases).undeployed.count, expanded,
                             "the fixture has to actually exercise the fold")

        let snapshot = OpsAsk.deployCard(doc, reading: reading).snapshotText
        for i in 0..<6 {
            XCTAssertTrue(snapshot.contains("Release number \(i)"),
                          "release \(i) is missing — the fold must not reach the snapshot")
        }
        XCTAssertTrue(snapshot.contains("Not yet deployed: 6 releases"))
        XCTAssertTrue(snapshot.contains("What is running"))
        XCTAssertTrue(snapshot.contains("4 older releases were dropped by the sentinel"),
                      "silent truncation reads as completeness")
    }

    /// A STALE view of `origin/main` says so in the reading itself, with its reason — not
    /// only in the card's title, which the snapshot does not carry.
    func testTheDeploySnapshotCarriesTheStalenessAndItsReason() throws {
        let fresh = OpsAsk.deployCard(try manyReleases(stale: false), reading: reading)
        XCTAssertFalse(fresh.snapshotText.contains("STALE"))

        let stale = OpsAsk.deployCard(try manyReleases(stale: true), reading: reading)
        let snapshot = stale.snapshotText
        XCTAssertTrue(snapshot.contains("STALE"))
        XCTAssertTrue(snapshot.contains("the GitHub API refused the last two reads"))
        XCTAssertTrue(snapshot.contains("may all be out of date"))
    }

    /// The button's own verdict, from the same `DeployAvailability` the button uses — so the
    /// chat cannot tell someone to press a button the screen is refusing.
    func testTheDeploySnapshotCarriesTheButtonsVerdictAndItsReason() throws {
        let ready = OpsAsk.deployCard(try withReleases(), reading: reading).snapshotText
        XCTAssertTrue(ready.contains("Deploy button: offered"))

        // Same sha both sides: the card refuses, naming why.
        let same = """
        {"deploy": null,
         "running": {"version": "0.107.0", "sha": "\(String(repeating: "b", count: 40))"},
         "origin_main": {"sha": "\(String(repeating: "b", count: 40))", "version": "0.107.0",
                         "ci": "green", "ci_detail": null, "checked_ms": 0}}
        """
        let doc = try DeployStatusDocument.decode(Data(same.utf8))
        let blocked = OpsAsk.deployCard(doc, reading: reading).snapshotText
        XCTAssertTrue(blocked.contains("not offered"))
        XCTAssertTrue(blocked.contains("origin/main is already what is running"))
    }

    /// A sentinel with no `releases` block is the ORDINARY case, not a fault — a deploy
    /// replaces the bridge, not the sentinel. The snapshot says which case it is rather than
    /// leaving the agent to read an absent list as "nothing to deploy".
    func testADocumentWithNoReleaseBlockSaysWhyRatherThanLookingCurrent() throws {
        let doc = try DeployStatusDocument.decode(
            Data(DeployReleasesTests.withoutReleases.utf8))
        let snapshot = OpsAsk.deployCard(doc, reading: reading).snapshotText
        XCTAssertTrue(snapshot.contains("predates the release-notes block"))
        XCTAssertTrue(snapshot.contains("routine, not a fault"))
    }

    /// A release pressed on its own still knows whether it is the one running, because
    /// "what did this change" and "would a deploy bring this in" are the same press.
    func testAReleaseBlockKnowsWhetherItIsWhatIsRunning() throws {
        let doc = try manyReleases()
        let running = try XCTUnwrap(doc.releases?.deployed)
        let pending = try XCTUnwrap(doc.releases?.undeployed.first)

        let runningSnapshot = OpsAsk.release(running, label: "Running release", in: doc,
                                             reading: reading).snapshotText
        XCTAssertTrue(runningSnapshot.contains("this release IS what is running"))

        let pendingSnapshot = OpsAsk.release(pending, label: nil, in: doc,
                                             reading: reading).snapshotText
        XCTAssertTrue(pendingSnapshot.contains("this release is NOT running yet"))
        XCTAssertTrue(pendingSnapshot.contains("It changed thing 0."))
    }

    /// A deploy in flight carries its phase, its reason and the NEWEST end of its log tail —
    /// the end a failure is at.
    func testDeployProgressKeepsTheNewestEndOfTheLogTail() throws {
        let lines = (1...40).map { "line \($0)" }
        let json = """
        {"deploy_id": "d-1", "phase": "build", "ref": "main",
         "sha": "\(String(repeating: "c", count: 40))", "started_ms": 1756600000000,
         "finished_ms": null, "result": null, "reason": null,
         "log_tail": [\(lines.map { "\"\($0)\"" }.joined(separator: ", "))]}
        """
        // Wrapped in a whole document, because that is how the record ever arrives.
        let doc = try DeployStatusDocument.decode(Data("""
        {"deploy": \(json.replacingOccurrences(of: "\n", with: " ")),
         "running": {"version": "0.100.0", "sha": null},
         "origin_main": {"sha": null, "version": null, "ci": "none", "ci_detail": null,
                         "checked_ms": 0}}
        """.utf8))
        let record = try XCTUnwrap(doc.deploy)
        let snapshot = OpsAsk.deployProgress(record, reading: reading).snapshotText
        XCTAssertTrue(snapshot.contains("in flight, phase build"))
        XCTAssertTrue(snapshot.contains("line 40"), "the newest line is the one that matters")
        XCTAssertFalse(snapshot.contains("line 1\n"), "the oldest lines are the capped ones")
        XCTAssertTrue(snapshot.contains("earlier line"), "and the cap says what it dropped")
    }

    // MARK: - Identity

    /// Ops keys live in their OWN namespace, differ per subject, and are stable for two
    /// presses in the same device day — which is exactly what makes a second press resume
    /// the conversation the first one started.
    func testScopeKeysAreNamespacedStableAndPerSubject() throws {
        let status = try healthy()
        let rows = status.serviceRows

        let bridge = OpsAsk.bridgeCard(status, reading: reading).scopeKey
        XCTAssertTrue(bridge.hasPrefix("ops/"), "\(bridge) is not in the Ops namespace")
        XCTAssertFalse(bridge.contains("health"), "an Ops key can never collide with a Health one")

        // Stable: the same press twice in the same day is the same reading.
        let later = OpsAskReading(taken: reading.taken.addingTimeInterval(3600),
                                  zone: reading.zone)
        XCTAssertEqual(bridge, OpsAsk.bridgeCard(status, reading: later).scopeKey)

        // And tomorrow is a different reading, so it gets its own conversation.
        let tomorrow = OpsAskReading(taken: reading.taken.addingTimeInterval(86_400),
                                     zone: reading.zone)
        XCTAssertNotEqual(bridge, OpsAsk.bridgeCard(status, reading: tomorrow).scopeKey)

        // Per subject: every card, and every row inside a card, is its own key.
        let keys = [
            bridge,
            OpsAsk.servicesCard(status, reading: reading).scopeKey,
            OpsAsk.serviceRow(rows[0], reading: reading).scopeKey,
            OpsAsk.serviceRow(rows[1], reading: reading).scopeKey,
            OpsAsk.diskCard(status, reading: reading).scopeKey,
            OpsAsk.gitCard(status, reading: reading).scopeKey,
            OpsAsk.qmdCard(status, reading: reading).scopeKey,
            OpsAsk.watchdogCard(status, reading: reading).scopeKey,
            OpsAsk.tailscaleCard(status, reading: reading).scopeKey,
            OpsAsk.ledgerSection(status.ledgerRows, reading: reading).scopeKey,
            OpsAsk.ledgerRow(status.ledgerRows[0], reading: reading).scopeKey,
            OpsAsk.ledgerRow(status.ledgerRows[1], reading: reading).scopeKey,
            OpsAsk.deployCard(try withReleases(), reading: reading).scopeKey,
            OpsAsk.page(status: status, deploy: nil, refreshError: nil,
                        isSentinelPaired: true, verbs: [], lastVerb: nil,
                        isRunningVerb: false, reading: reading).scopeKey,
        ]
        XCTAssertEqual(Set(keys).count, keys.count, "two subjects share a key: \(keys)")
        for key in keys { XCTAssertTrue(key.hasPrefix("ops/")) }
    }

    /// Two different releases are two different readings even when they share a title and a
    /// version — which the real payload does, which is why the sha is the identity.
    func testTwoReleasesSharingEveryVisibleFieldStillGetTheirOwnKeys() throws {
        let doc = try withReleases()
        let releases = try XCTUnwrap(doc.releases)
        XCTAssertEqual(releases.undeployed[0].title, releases.undeployed[1].title)
        XCTAssertNotEqual(
            OpsAsk.release(releases.undeployed[0], label: nil, in: doc, reading: reading).scopeKey,
            OpsAsk.release(releases.undeployed[1], label: nil, in: doc, reading: reading).scopeKey)
    }

    /// The reading's day key is a fixed format, not a localized one: it is an IDENTITY, and
    /// a key that moved with the device's locale would silently stop resuming.
    func testTheReadingsDayKeyIsFixedFormat() {
        let r = OpsAskReading(taken: Date(timeIntervalSince1970: 1_789_050_720),
                              zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(r.range.key, "at:2026-09-10")
        // The same instant, one zone west of the date line's worth of offset, is a different
        // day — the DEVICE's day, because the person reading it is holding the device.
        let auckland = OpsAskReading(taken: r.taken,
                                     zone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(auckland.range.key, "at:2026-09-11")
    }

    // MARK: - Budget

    /// A snapshot that reaches the ceiling is cut AT A LINE BOUNDARY and says it was cut.
    /// Never mid-number, and never silently: a truncated reading that does not admit it is
    /// how an agent concludes a machine is fine.
    func testAnOversizedSnapshotIsClampedAtALineBoundaryAndSaysSo() throws {
        // A ledger reason long enough to blow the ceiling on its own, which is the shape
        // that actually does it: log and error strings come from other systems.
        let json = """
        {"at_ms": 1756000330000, "job": "overnight", "outcome": "failed",
         "reason": "\(String(repeating: "why ", count: 6_000))"}
        """
        let row = try JSONDecoder().decode(LedgerRow.self, from: Data(json.utf8))
        let snapshot = OpsAsk.ledgerRow(row, reading: reading).snapshotText

        XCTAssertLessThanOrEqual(snapshot.count, AskBudget.maxCharacters + 100)
        XCTAssertTrue(snapshot.hasSuffix("(snapshot truncated here to fit — "
            + "ask for any part of it in full)"))
        // The cut fell at a newline, so no line is half a fact.
        let body = snapshot.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        XCTAssertFalse(body.isEmpty)
    }

    /// A ledger longer than the cap keeps the newest lines and says how many it left out.
    func testALongLedgerSaysHowManyLinesItLeftOut() throws {
        let rows = (0..<30).map { i -> LedgerRow in
            var row = try! JSONDecoder().decode(LedgerRow.self, from: Data("""
            {"at_ms": 175600033000\(i % 10), "job": "job-\(i)", "outcome": "fired"}
            """.utf8))
            row.id = i
            return row
        }
        let snapshot = OpsAsk.ledgerSection(rows, reading: reading).snapshotText
        XCTAssertTrue(snapshot.contains("job-0"), "the newest end is kept")
        XCTAssertFalse(snapshot.contains("job-29"))
        XCTAssertTrue(snapshot.contains("18 more ledger lines not listed"))
    }
}
