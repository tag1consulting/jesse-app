import XCTest
import JesseNetworking
@testable import JesseOps

// What the four ops documents decode to.
//
// Every fixture here is the SHAPE THE SENTINEL AND BRIDGE ACTUALLY EMIT, taken from the
// `json!` blocks in `bridge/src/sentinel/probes.rs`, `bridge/src/sentinel/deploy.rs`,
// `bridge/src/scheduler.rs` and `bridge/src/profile.rs` — including the parts a happy-path
// fixture leaves out and a real outage does not: a probe that timed out (`unknown`, with a
// null detail), a `last exit code = (never exited)` that arrives as null, an origin/main view
// that is stale, and an away period that is on disk but no longer in force.

final class OpsDocumentDecodeTests: XCTestCase {

    // MARK: - Status

    /// A whole document with every probe healthy, plus the two nulls that a naive decode
    /// treats as zero: `last_exit_code` (launchd's `(never exited)`) and `behind`.
    func testStatusDecodesAHealthyDocument() throws {
        let doc = try SentinelStatusDocument.decode(Data(Self.healthyStatus.utf8))

        XCTAssertEqual(doc.sentinel?.version, "0.94.0")
        XCTAssertEqual(doc.sentinel?.watchdog?.kickstartsLastHour, 2)
        XCTAssertNil(doc.sentinel?.watchdog?.gaveUpMs, "nothing has given up on this host")

        XCTAssertEqual(doc.bridge.health, .green)
        XCTAssertEqual(doc.bridge.detail?.latencyMs, 12)
        XCTAssertEqual(doc.bridge.detail?.health?.version, "0.94.0")
        XCTAssertEqual(doc.bridge.detail?.health?.profile, "home")
        XCTAssertEqual(doc.bridge.detail?.health?.drift?.count, 1)

        let rows = doc.serviceRows
        XCTAssertEqual(rows.map(\.id), ["bridge", "autocommit"],
                       "rows come back in the sentinel's own slot order, not the dictionary's")
        XCTAssertEqual(rows[0].label, "com.example.jesse-bridge")
        XCTAssertNil(rows[0].lastExitCode,
                     "`(never exited)` is null and must NEVER read as a clean exit 0")
        XCTAssertEqual(rows[1].lastExitCode, 1)

        XCTAssertEqual(doc.disk.detail?.volumes?.count, 2)
        XCTAssertEqual(doc.disk.detail?.artifactsComplete, true)
        XCTAssertEqual(doc.git.detail?.branch, "main")
        XCTAssertEqual(doc.git.detail?.ahead, 0)
        XCTAssertNil(doc.git.detail?.behind, "an unreadable ahead/behind is absent, not zero")
        XCTAssertEqual(doc.git.detail?.lastAutocommitLine?.published, true)
        XCTAssertEqual(doc.qmd.detail?.nodeVersion, "v22.14.0")

        XCTAssertEqual(doc.ledgerRows.count, 2)
        XCTAssertEqual(doc.ledgerRows.first?.job, "morning", "newest first")
        XCTAssertEqual(doc.schedule.detail?.jobs.count, 1)
    }

    /// The case the whole `Probe` type exists for: a probe that did not finish. `unknown` is
    /// not `failed`, its detail is null, and it must not take the document down with it.
    func testStatusSurvivesUnknownProbesAndNullDetails() throws {
        let doc = try SentinelStatusDocument.decode(Data(Self.degradedStatus.utf8))

        XCTAssertEqual(doc.tailscale.state, .unknown)
        XCTAssertEqual(doc.tailscale.health, .grey, "grey is not a shade of red")
        XCTAssertNil(doc.tailscale.detail)
        XCTAssertEqual(doc.tailscale.error, "tailscale probe did not finish within 5s")

        XCTAssertEqual(doc.disk.state, .failed)
        XCTAssertEqual(doc.disk.health, .red)
        // A failed probe still carries its detail — that is what makes the card useful.
        XCTAssertEqual(doc.disk.detail?.freeBytesMin, 1_000_000)

        XCTAssertEqual(doc.services.health, .grey)
        XCTAssertTrue(doc.serviceRows.isEmpty)
        XCTAssertTrue(doc.ledgerRows.isEmpty)
        XCTAssertNil(doc.schedule.detail)
    }

    /// `ok` WITH a note is amber, not green: an artifact store that does not exist yet is not
    /// a fault, but painting it green would read as "checked and fine".
    func testAnOkProbeCarryingANoteIsAmber() throws {
        let doc = try SentinelStatusDocument.decode(Data(Self.degradedStatus.utf8))
        XCTAssertEqual(doc.ledgerTail.state, .ok)
        XCTAssertEqual(doc.ledgerTail.health, .amber)
    }

    /// A ledger line that was not JSON arrives as `{"raw": …}` and is KEPT — a ledger emitting
    /// garbage is a thing to see, not to hide.
    func testALedgerLineThatIsNotJsonSurvivesAsRaw() throws {
        let doc = try SentinelStatusDocument.decode(Data(Self.healthyStatus.utf8))
        XCTAssertEqual(doc.ledgerRows.last?.raw, "Segmentation fault: 11")
    }

    /// A probe whose `detail` changed shape must cost its card's detail and nothing else.
    func testAnUnreadableDetailDoesNotFailTheDocument() throws {
        // The brace the original `detail` opened is re-used by `unused`, so the document stays
        // balanced and only the ONE field this test is about changes shape.
        let json = Self.healthyStatus.replacingOccurrences(
            of: #""detail": {"volumes": ["#,
            with: #""detail": "a string, somehow", "unused": {"volumes": ["#)
        let doc = try SentinelStatusDocument.decode(Data(json.utf8))
        XCTAssertNil(doc.disk.detail)
        XCTAssertEqual(doc.disk.state, .ok, "the envelope is the contract; the detail is not")
        XCTAssertEqual(doc.bridge.detail?.latencyMs, 12, "every other card is untouched")
    }

    // MARK: - Schedule

    func testScheduleDecodesRowsAndInvalidEntries() throws {
        let doc = try ScheduleDocument.decode(Data(Self.schedule.utf8))
        XCTAssertEqual(doc.tz, "Europe/Rome")
        XCTAssertEqual(doc.utcOffset, "+02:00")
        XCTAssertEqual(doc.persistent, true)
        XCTAssertEqual(doc.profile?.name, "home")
        XCTAssertEqual(doc.onReturn, "catch-up")
        XCTAssertEqual(doc.jobs.count, 4)

        let head = try XCTUnwrap(doc.jobs.first { $0.id == "overnight" })
        XCTAssertTrue(head.isHead)
        XCTAssertEqual(head.at, "03:30")
        XCTAssertEqual(head.resolvedDays, "every day")
        XCTAssertEqual(head.profiles, ["home", "away"])
        XCTAssertEqual(head.lastOutcome, "fired")
        XCTAssertEqual(head.consecutiveFailures, 0)
        XCTAssertEqual(head.outputLabel, "notes/2026-08-24-overnight.md")

        let link = try XCTUnwrap(doc.jobs.first { $0.id == "diet-extract" })
        XCTAssertFalse(link.isHead)
        XCTAssertEqual(link.after, "overnight")
        XCTAssertEqual(link.whenLabel, "after overnight (success)")
        XCTAssertEqual(link.consecutiveFailures, 6)
        XCTAssertEqual(link.outputLabel, "no output contract")

        let overridden = try XCTUnwrap(doc.jobs.first { $0.id == "weekly" })
        XCTAssertEqual(overridden.enabled, false)
        XCTAssertEqual(overridden.enabledConfig, true)
        XCTAssertEqual(overridden.override?.enabled, false)
        XCTAssertEqual(overridden.override?.active, true)
        XCTAssertEqual(overridden.resolvedDays, "Mon")
        XCTAssertEqual(overridden.promotedFrom, "weekly-old")

        XCTAssertEqual(doc.invalid.map(\.id), ["typo"])
        XCTAssertEqual(doc.invalid.first?.reason, "`at` must be HH:MM, got \"25:00\"")
    }

    /// A schedule with no `invalid` key at all is a schedule with no invalid entries — not a
    /// decode failure.
    func testScheduleWithoutInvalidKeyDecodes() throws {
        let doc = try ScheduleDocument.decode(Data(#"{"jobs": [], "tz": "UTC"}"#.utf8))
        XCTAssertTrue(doc.jobs.isEmpty)
        XCTAssertTrue(doc.invalid.isEmpty)
    }

    /// The reload verb answers the same document one level down, beside what it did.
    func testReloadResultCarriesTheFreshDocument() throws {
        let json = #"{"reloaded": true, "errors": ["entry 3: `mode` must be ask or tell"], "schedule": "#
            + Self.schedule + "}"
        let result = try ScheduleDocument.ReloadResult.decode(Data(json.utf8))
        XCTAssertTrue(result.reloaded)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.schedule?.jobs.count, 4)
    }

    // MARK: - Profile

    func testProfileDecodesAnAwayPeriodInForce() throws {
        let doc = try ProfileDocument.decode(Data(Self.awayProfile.utf8))
        XCTAssertEqual(doc.name, "away")
        XCTAssertTrue(doc.isAway)
        XCTAssertEqual(doc.tz, "America/New_York")
        XCTAssertEqual(doc.processTz, "Europe/Rome")
        XCTAssertEqual(doc.note, "conference")
        XCTAssertNotNil(doc.until)
        XCTAssertNil(doc.returnedMs, "the on-return chain is still owed")
        XCTAssertNotNil(doc.awayBannerText)
        XCTAssertTrue(try XCTUnwrap(doc.awayBannerText).contains("America/New_York"))
    }

    /// THE CASE A SCREEN GETS WRONG: the period is still on disk, so `until_ms` is set, but it
    /// has lapsed — `name` is `home` and `effective` is false. Reading `until_ms` as proof of
    /// being away is how a banner comes to say "away until last Tuesday".
    func testProfileTellsAStoredPeriodFromAnEffectiveOne() throws {
        let doc = try ProfileDocument.decode(Data(Self.lapsedProfile.utf8))
        XCTAssertEqual(doc.name, "home")
        XCTAssertFalse(doc.isAway)
        XCTAssertNotNil(doc.untilMs, "the stored period is still on record")
        XCTAssertNil(doc.awayBannerText, "…and the banner does not show")
    }

    /// A bridge that only answers `{name, effective}` still decodes: everything else is
    /// context around those two.
    func testProfileDecodesAMinimalBody() throws {
        let doc = try ProfileDocument.decode(Data(#"{"name":"home","effective":false}"#.utf8))
        XCTAssertFalse(doc.isAway)
        XCTAssertEqual(doc.note, "")
    }

    // MARK: - Deploy

    func testDeployStatusDecodesTheCard() throws {
        let doc = try DeployStatusDocument.decode(Data(Self.deployRunning.utf8))
        XCTAssertEqual(doc.running.version, "0.93.0")
        XCTAssertEqual(OpsFormat.shortSha(doc.running.sha), "aaaaaaa")
        XCTAssertEqual(doc.originMain.ci, "green")
        XCTAssertEqual(doc.originMain.ciHealth, .green)
        XCTAssertFalse(doc.originMain.isStale, "an absent `stale` key means current")

        let record = try XCTUnwrap(doc.deploy)
        XCTAssertEqual(record.phase, "build")
        XCTAssertEqual(record.gitRef, "main", "`ref` is a Swift keyword; the key is not")
        XCTAssertTrue(record.inFlight, "no `result` yet means still running")
        XCTAssertEqual(record.logTail.count, 2)
    }

    /// Nothing has ever been deployed on a fresh state, and the shape says so explicitly
    /// rather than omitting the fields.
    func testDeployStatusDecodesAnEmptyCard() throws {
        let json = #"""
        {"deploy": null,
         "running": {"version": null, "sha": null},
         "origin_main": {"sha": null, "version": null, "ci": "none", "ci_detail": null,
                         "checked_ms": 0, "stale": true,
                         "stale_reason": "the clone does not exist yet"}}
        """#
        let doc = try DeployStatusDocument.decode(Data(json.utf8))
        XCTAssertNil(doc.deploy)
        XCTAssertNil(doc.running.sha)
        XCTAssertTrue(doc.originMain.isStale)
        XCTAssertEqual(doc.originMain.staleReason, "the clone does not exist yet")
    }

    /// A rollback: the record is terminal (`result` present), so nothing polls it any more,
    /// and it carries the reason the deploy was undone.
    func testDeployRecordReadsATerminalResult() throws {
        let json = #"""
        {"deploy": {"deploy_id": "d-20260824-1", "phase": "finish", "ref": "main",
                    "sha": "bbbbbbb", "started_ms": 1756000000000,
                    "finished_ms": 1756001200000, "result": "rolled_back",
                    "reason": "the new bridge did not come up healthy", "log_tail": []},
         "running": {"version": "0.93.0", "sha": "aaaaaaa"},
         "origin_main": {"sha": "bbbbbbb", "version": "0.94.0", "ci": "green",
                         "ci_detail": null, "checked_ms": 1}}
        """#
        let doc = try DeployStatusDocument.decode(Data(json.utf8))
        let record = try XCTUnwrap(doc.deploy)
        XCTAssertFalse(record.inFlight)
        XCTAssertEqual(record.resultHealth, .red)
        XCTAssertEqual(record.reason, "the new bridge did not come up healthy")
    }

    // MARK: - Fixtures

    static let healthyStatus = #"""
    {
      "sentinel": {"version": "0.94.0", "uptime_secs": 4000, "now_ms": 1756000000000,
                   "watchdog": {"last_tick_ms": 1755999990000, "bridge_misses": 0,
                                "kickstarts_last_hour": 2, "gave_up_ms": null,
                                "last_error": null}},
      "bridge": {"ok": true, "state": "ok",
                 "detail": {"reachable": true, "status": 200, "latency_ms": 12,
                            "health": {"version": "0.94.0", "profile": "home",
                                       "tz": "Europe/Rome", "drift": ["morning +40s"]}},
                 "error": null},
      "services": {"ok": true, "state": "ok",
                   "detail": {"bridge": {"state": "running", "pid": 15818,
                                         "last_exit_code": null, "runs": 7,
                                         "label": "com.example.jesse-bridge"},
                              "autocommit": {"state": "not running", "pid": null,
                                             "last_exit_code": 1, "runs": 412,
                                             "label": "com.example.jesse-autocommit"}},
                   "error": null},
      "tailscale": {"ok": true, "state": "ok",
                    "detail": {"online": true, "ips": ["100.64.0.1"],
                               "dns_name": "studio.tailnet.ts.net."},
                    "error": null},
      "disk": {"ok": true, "state": "ok", "detail": {"volumes": [
                 {"path": "/Users/you/vault", "free_bytes": 400000000000, "total_bytes": 990000000000},
                 {"path": "/Users/you/.jesse", "free_bytes": 400000000000, "total_bytes": 990000000000}],
                 "free_bytes_min": 400000000000, "floor_bytes": 5000000000,
                 "artifacts_bytes": 12345678, "artifacts_files": 42,
                 "artifacts_complete": true}, "error": null},
      "git": {"ok": true, "state": "ok",
              "detail": {"repo": "/Users/you/vault", "branch": "main", "ahead": 0,
                         "behind": null, "dirty": false, "index_lock_age_secs": null,
                         "conflicts": [],
                         "last_autocommit_line": {"line": "autocommit: 3 files", "published": true}},
              "error": null},
      "qmd": {"ok": true, "state": "ok",
              "detail": {"exit_code": 0, "first_stderr_line": null, "child_path_set": true,
                         "node_version": "v22.14.0"}, "error": null},
      "ledger_tail": {"ok": true, "state": "ok", "detail": [
                        {"raw": "Segmentation fault: 11"},
                        {"at": "2026-08-24T03:32:10+02:00", "at_ms": 1756000330000,
                         "job": "morning", "outcome": "fired", "reason": "",
                         "fired_at_ms": 1756000300000, "duration_ms": 30000,
                         "job_id": "j-1"}], "error": null},
      "schedule": {"ok": true, "state": "ok",
                   "detail": {"now_ms": 1756000000000, "tz": "Europe/Rome",
                              "utc_offset": "+02:00", "persistent": true,
                              "jobs": [{"id": "overnight", "enabled": true, "kind": "head",
                                        "after": null, "at": "03:30"}],
                              "invalid": []},
                   "error": null}
    }
    """#

    static let degradedStatus = #"""
    {
      "sentinel": {"version": "0.94.0", "uptime_secs": 10, "now_ms": 1756000000000,
                   "watchdog": {"last_tick_ms": null, "bridge_misses": 3,
                                "kickstarts_last_hour": 5, "gave_up_ms": 1755999000000,
                                "last_error": "connection refused"}},
      "bridge": {"ok": false, "state": "failed",
                 "detail": {"reachable": false, "latency_ms": null, "health": null},
                 "error": "connection refused"},
      "services": {"ok": null, "state": "unknown", "detail": null,
                   "error": "launchctl print gui/501/com.example.jesse-bridge: timed out"},
      "tailscale": {"ok": null, "state": "unknown", "detail": null,
                    "error": "tailscale probe did not finish within 5s"},
      "disk": {"ok": false, "state": "failed",
               "detail": {"volumes": [], "free_bytes_min": 1000000, "floor_bytes": 5000000000,
                          "artifacts_bytes": 0, "artifacts_files": 0,
                          "artifacts_complete": false},
               "error": "only 0 MB free — under the 5 GB floor"},
      "git": {"ok": null, "state": "unknown", "detail": null, "error": "git in /vault: timed out"},
      "qmd": {"ok": null, "state": "unknown", "detail": null, "error": "qmd status: not found"},
      "ledger_tail": {"ok": true, "state": "ok", "detail": [],
                      "error": "/Users/you/.jesse/ledger.jsonl does not exist yet"},
      "schedule": {"ok": false, "state": "failed", "detail": null,
                   "error": "connection refused"}
    }
    """#

    static let schedule = #"""
    {
      "now_ms": 1756000000000,
      "profile": {"name": "home", "tz": "Europe/Rome", "until_ms": null, "note": ""},
      "on_return": "catch-up",
      "tz": "Europe/Rome",
      "utc_offset": "+02:00",
      "persistent": true,
      "jobs": [
        {"id": "overnight", "enabled": true, "enabled_config": true, "kind": "head",
         "after": null, "after_on": null, "at": "03:30", "days": [],
         "profiles": ["home", "away"], "mode": "tell", "prompt": "(file)", "notify": false,
         "timeout_secs": 3600, "catch_up_secs": 1800, "running": false,
         "next_fire_ms": 1756060200000, "retry_due_ms": null,
         "last_fire_ms": 1755973800000, "last_completion_ms": 1755974100000,
         "last_outcome": "fired", "last_reason": "", "last_duration_ms": 300000,
         "last_job_id": "j-1", "consecutive_failures": 0,
         "expect_output": "notes/{date}-overnight.md",
         "last_output_path": "notes/2026-08-24-overnight.md", "model": null,
         "promoted_from": null, "override": null},
        {"id": "diet-extract", "enabled": true, "enabled_config": true, "kind": "link",
         "after": "overnight", "after_on": "success", "at": null, "days": [],
         "profiles": ["home", "away"], "mode": "tell", "prompt": "(file)", "notify": false,
         "timeout_secs": 1800, "catch_up_secs": null, "running": false,
         "next_fire_ms": null, "retry_due_ms": null,
         "last_fire_ms": 1755974200000, "last_completion_ms": 1755974300000,
         "last_outcome": "failed", "last_reason": "the model returned no valid time",
         "last_duration_ms": 100000, "last_job_id": "j-2", "consecutive_failures": 6,
         "expect_output": null, "last_output_path": null, "model": null,
         "promoted_from": null, "override": null},
        {"id": "weekly", "enabled": false, "enabled_config": true, "kind": "head",
         "after": null, "after_on": null, "at": "09:00", "days": ["Mon"],
         "profiles": ["home"], "mode": "ask", "prompt": "(inline)", "notify": true,
         "timeout_secs": 900, "catch_up_secs": 600, "running": false,
         "next_fire_ms": 1756108800000, "retry_due_ms": null,
         "last_fire_ms": null, "last_completion_ms": null, "last_outcome": null,
         "last_reason": null, "last_duration_ms": null, "last_job_id": null,
         "consecutive_failures": 0, "expect_output": null, "last_output_path": null,
         "model": "opus", "promoted_from": "weekly-old",
         "override": {"enabled": false, "until_ms": 1756300000000,
                      "set_ms": 1755900000000, "active": true}},
        {"id": "orphan", "enabled": true, "enabled_config": true, "kind": "link",
         "after": "a-job-that-does-not-exist", "after_on": "completion", "at": null,
         "days": [], "profiles": ["home", "away"], "mode": "tell", "prompt": "(file)",
         "notify": false, "timeout_secs": 600, "catch_up_secs": null, "running": false,
         "next_fire_ms": null, "retry_due_ms": null, "last_fire_ms": null,
         "last_completion_ms": null, "last_outcome": null, "last_reason": null,
         "last_duration_ms": null, "last_job_id": null, "consecutive_failures": 0,
         "expect_output": null, "last_output_path": null, "model": null,
         "promoted_from": null, "override": null}
      ],
      "invalid": [{"id": "typo", "reason": "`at` must be HH:MM, got \"25:00\""}]
    }
    """#

    static let awayProfile = #"""
    {"name": "away", "tz": "America/New_York", "since_ms": 1755900000000,
     "until_ms": 1756500000000, "note": "conference", "effective": true,
     "process_tz": "Europe/Rome", "returned_ms": null}
    """#

    static let lapsedProfile = #"""
    {"name": "home", "tz": "Europe/Rome", "since_ms": 1750000000000,
     "until_ms": 1751000000000, "note": "last trip", "effective": false,
     "process_tz": "Europe/Rome", "returned_ms": 1751000100000}
    """#

    static let deployRunning = #"""
    {"deploy": {"deploy_id": "d-20260824-1", "phase": "build", "ref": "main",
                "sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "started_ms": 1756000000000, "finished_ms": null, "result": null,
                "reason": null, "log_tail": ["cargo build --release", "Compiling jesse-bridge"]},
     "running": {"version": "0.93.0", "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
     "origin_main": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "version": "0.94.0",
                     "ci": "green", "ci_detail": "run 12345 concluded success",
                     "checked_ms": 1755999000000}}
    """#
}
