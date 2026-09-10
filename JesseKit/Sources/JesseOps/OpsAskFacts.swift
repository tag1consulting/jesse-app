import Foundation
import JesseAsk

// The UNIT serializers: one function per thing the Ops screens draw, each turning it into
// the lines a chat needs to answer questions about it.
//
// This is the layer that makes "one serializer per unit, and the scopes compose them"
// true. There is exactly one serializer per UNIT (a probe envelope, a service row, a
// volume, a ledger line, a release, a deploy record, a schedule row), and the scope
// factories in `OpsAskContext.swift` compose them: a card is its units' blocks, the page
// is its cards'. Adding a card is one function here; widening a scope is one line there.
//
// Everything is a pure function of values the view already holds. Nothing here fetches,
// and nothing here re-derives a judgement: the dots come from `Probe.health`,
// `ServiceRow.health` and `OpsFormat.outcomeHealth`, the button's verdict from
// `DeployAvailability.decide`, the byte counts from `OpsFormat.bytes`. Those are the same
// functions the pixels came from, which is what guarantees the chat and the screen cannot
// disagree.
//
// UNKNOWN IS NOT ZERO survives into the snapshot, exactly as it does on screen. A probe
// that timed out says "unknown", not "failed". A `last_exit_code` the sentinel sent as null
// is absent rather than written as 0, because launchd's "(never exited)" and "exited
// cleanly" are different facts. A partial artifact walk says its size is a floor. A
// snapshot that quietly flattened any of those would let the agent state as fact something
// the screen is careful never to claim.

enum OpsFacts {

    // MARK: - The probe envelope, shared by seven cards

    /// A probe's own report: its dot in words, launchd's / the prober's own state string,
    /// and the error line the card prints under it.
    ///
    /// Generic over the detail, because the ENVELOPE is what every card shares and the
    /// detail is what makes each card different — the same split `Probe` itself draws.
    static func probe<D>(_ probe: Probe<D>?, named title: String) -> [String] {
        guard let probe else { return ["\(title): the sentinel has not answered yet"] }
        var line = "\(title): \(probe.health.word) · the probe says \(probe.state.rawValue)"
        if let error = probe.error, !error.isEmpty { line += " · \(error)" }
        return [line]
    }

    // MARK: - Bridge

    static func bridge(_ probe: Probe<BridgeProbeDetail>?) -> AskFacts {
        var lines = Self.probe(probe, named: "Reachability")
        if let d = probe?.detail {
            lines.append("Version: \(d.health?.version ?? "unknown")")
            lines.append("Latency: \(d.latencyMs.map { "\($0) ms" } ?? "unknown")")
            lines.append("Profile: \(d.health?.profile ?? "home")")
            if let tz = d.health?.tz { lines.append("Zone: \(tz)") }
            // The COUNT, as the card shows it. The drift array itself is a diagnostic the
            // bridge's own log carries in full, and the screen deliberately does not print
            // it — so neither does the snapshot.
            lines.append("Drift entries: \(d.health?.drift?.count ?? 0)")
        }
        return AskFacts(heading: "Bridge", lines: lines)
    }

    // MARK: - Services

    /// One launchd job: its dot, and the same `state · pid · last exit · runs` line the row
    /// prints, from the same builder.
    static func service(_ row: ServiceRow) -> AskFacts {
        var lines = ["\(row.health.word) · \(OpsFormat.serviceState(row))"]
        if let label = row.label, label != row.id { lines.append("launchd label: \(label)") }
        if let error = row.error, !error.isEmpty { lines.append("error: \(error)") }
        return AskFacts(heading: row.id, lines: lines)
    }

    static func services(_ probe: Probe<[String: ServiceRow]>?, rows: [ServiceRow],
                         limit: Int = AskBudget.maxListItems) -> AskFacts {
        let (kept, note) = AskBudget.cap(rows, limit: limit, noun: "services",
                                         totalsCoverAll: false)
        return AskFacts(heading: "Services",
                        lines: Self.probe(probe, named: "launchd"),
                        children: kept.map(service), note: note)
    }

    // MARK: - Tailscale

    static func tailscale(_ probe: Probe<TailscaleDetail>?) -> AskFacts {
        var lines = Self.probe(probe, named: "Tailnet")
        if let d = probe?.detail {
            lines.append("Online: \((d.online ?? false) ? "yes" : "no")")
            if let name = d.dnsName { lines.append("Name: \(name)") }
            if let ips = d.ips, !ips.isEmpty {
                lines.append("Addresses: \(ips.joined(separator: ", "))")
            }
        }
        return AskFacts(heading: "Tailscale", lines: lines)
    }

    // MARK: - Disk

    static func disk(_ probe: Probe<DiskDetail>?) -> AskFacts {
        var lines = Self.probe(probe, named: "Free space")
        var note: String?
        if let d = probe?.detail {
            for v in d.volumes ?? [] {
                lines.append("\(v.path): \(OpsFormat.bytes(v.freeBytes)) free of "
                    + "\(OpsFormat.bytes(v.totalBytes))")
            }
            lines.append("Artifacts: \(OpsFormat.bytes(d.artifactsBytes)) in "
                + "\(d.artifactsFiles ?? 0) files")
            if d.artifactsComplete == false {
                // The floor caveat, carried rather than dropped: an under-reported store
                // reads as "there is nothing to prune".
                note = "the artifact walk hit its entry ceiling, so that size is a floor, "
                    + "not a total"
            }
        }
        return AskFacts(heading: "Disk", lines: lines, note: note)
    }

    // MARK: - Git

    static func git(_ probe: Probe<GitDetail>?) -> AskFacts {
        var lines = Self.probe(probe, named: "Vault")
        if let d = probe?.detail {
            lines.append("Branch: \(d.branch ?? "unknown")")
            lines.append("Ahead / behind: \(d.ahead.map(String.init) ?? "?")"
                + " / \(d.behind.map(String.init) ?? "?")")
            lines.append("Working tree: \((d.dirty ?? false) ? "dirty" : "clean")")
            lines.append("Index lock: \(d.indexLockAgeSecs.map { "\($0)s old" } ?? "none")")
            if let c = d.conflicts, !c.isEmpty {
                lines.append("Conflicts: \(c.joined(separator: ", "))")
            }
            if let line = d.lastAutocommitLine?.line {
                lines.append("Last autocommit: \(line)")
                if d.lastAutocommitLine?.published == false {
                    lines.append("that autocommit is NOT published")
                }
            }
            if let e = d.lastAutocommitLine?.error, !e.isEmpty {
                lines.append("autocommit error: \(e)")
            }
        }
        return AskFacts(heading: "Git", lines: lines)
    }

    // MARK: - QMD

    static func qmd(_ probe: Probe<QmdDetail>?) -> AskFacts {
        var lines = Self.probe(probe, named: "Index")
        if let d = probe?.detail {
            if let node = d.nodeVersion { lines.append("Node: \(node)") }
            if let line = d.firstStderrLine, !line.isEmpty { lines.append(line) }
        }
        return AskFacts(heading: "QMD", lines: lines)
    }

    // MARK: - Watchdog

    static func watchdog(_ sentinel: SentinelSelf?, now: Date) -> AskFacts {
        let w = sentinel?.watchdog
        var lines = [
            "Last tick: \(OpsFormat.relative(fromMs: w?.lastTickMs, now: now) ?? "never")",
            "Kickstarts (last hour): \(w?.kickstartsLastHour ?? 0)",
        ]
        if let gaveUp = w?.gaveUpMs {
            // The single most important line on the page when it is set, and it is spelled
            // out here for the same reason it is spelled out on screen: "the bridge is
            // down" and "the bridge is down AND nothing is trying to fix it" are different
            // situations.
            lines.append("GAVE UP \(OpsFormat.relative(fromMs: gaveUp, now: now) ?? "")"
                + " — nothing is trying to restart the bridge any more")
        }
        if let e = w?.lastError, !e.isEmpty { lines.append("Last error: \(e)") }
        lines.append("Sentinel: \(sentinel?.version ?? "unknown")")
        return AskFacts(heading: "Watchdog", lines: lines)
    }

    // MARK: - Ledger

    /// One fire-ledger line, in the same two shapes the row renders: a parsed line, or the
    /// raw text the ledger emitted when it was not JSON — SHOWN, because a ledger emitting
    /// garbage is a thing to see rather than to hide.
    static func ledgerRow(_ row: LedgerRow, bridgeTz: String?) -> AskFacts {
        if let raw = row.raw {
            return AskFacts(heading: "unparsed ledger line", lines: [raw])
        }
        var lines = ["\(OpsFormat.outcomeHealth(row.outcome).word) · outcome "
            + "\(row.outcome ?? "—")",
                     "when: \(OpsFormat.inBothZones(row.atMs, bridgeTz: bridgeTz))"]
        if let reason = row.reason, !reason.isEmpty { lines.append("reason: \(reason)") }
        if let ms = row.durationMs, let d = OpsFormat.duration(ms: ms) {
            lines.append("took \(d)")
        }
        return AskFacts(heading: row.job ?? "—", lines: lines)
    }

    /// The ledger as the section shows it: newest first, capped, and saying how many of the
    /// loaded lines it left out.
    static func ledger(_ rows: [LedgerRow], bridgeTz: String?,
                       limit: Int = AskBudget.maxListItems) -> AskFacts {
        guard !rows.isEmpty else {
            return AskFacts(heading: "Ledger",
                            lines: ["the scheduler has not written a ledger line yet"])
        }
        let (kept, note) = AskBudget.cap(rows, limit: limit, noun: "ledger lines",
                                         totalsCoverAll: false)
        return AskFacts(heading: "Ledger (newest first)",
                        children: kept.map { ledgerRow($0, bridgeTz: bridgeTz) },
                        note: note)
    }

    // MARK: - Actions

    /// The verbs the screen offers and the outcome of the last one pressed.
    ///
    /// It carries the verbs as a LIST OF WHAT IS OFFERED, deliberately without any of the
    /// confirmation dialogs' consequence text: the prompt forbids the agent to take any of
    /// these actions, and the screen is where the consequence is read before pressing.
    static func actions(_ verbs: [OpsAction], last: OpsModel.VerbOutcome?,
                        isRunning: Bool) -> AskFacts {
        var lines = ["Offered: \(verbs.map(\.buttonTitle).joined(separator: ", "))"]
        if isRunning { lines.append("a verb is in flight right now, so all of them are disabled") }
        if let last {
            lines.append("Last verb: \(last.verb) — \(last.succeeded ? "succeeded" : "FAILED")"
                + " · \(last.detail)")
        }
        return AskFacts(heading: "Actions", lines: lines,
                        note: "these are buttons on the screen; nothing here has been pressed")
    }

    // MARK: - Deploy

    /// One release: its title, its component-qualified subtitle, every claim line, and the
    /// count of further changes the sentinel did not list.
    static func release(_ r: DeployStatusDocument.Release, label: String?,
                        limit: Int = AskBudget.maxNestedListItems) -> AskFacts {
        let (kept, note) = AskBudget.cap(r.lines, limit: limit, noun: "changelog lines",
                                         totalsCoverAll: false)
        var lines = ["\(r.subtitle)"]
        lines += kept
        if r.more > 0 { lines.append("+\(r.more) further change\(r.more == 1 ? "" : "s") "
            + "the sentinel did not list") }
        return AskFacts(heading: label.map { "\($0): \(r.title)" } ?? r.title,
                        lines: lines, note: note)
    }

    /// The release notes — and the ONE place this serializer deliberately shows MORE than
    /// the screen does.
    ///
    /// The card folds all but the newest few undeployed releases behind a disclosure group,
    /// because a Studio twelve releases behind would push the Deploy button off the screen.
    /// A snapshot has no such constraint and the question is "what would a deploy bring
    /// in", so it carries EVERY undeployed release the document holds, up to the budget,
    /// and says how many it capped. It also carries the count the SENTINEL truncated out of
    /// the document before the app ever saw it: two different losses, both stated, because
    /// silent truncation reads as completeness.
    static func releases(_ releases: DeployStatusDocument.Releases,
                         limit: Int = AskBudget.maxListItems) -> AskFacts {
        var children: [AskFacts] = []
        if let deployed = releases.deployed {
            children.append(release(deployed, label: "Running release"))
        }
        var lines: [String] = []
        var note: String?
        if releases.undeployed.isEmpty {
            if let why = releases.reason {
                lines.append("No release list: \(why)")
            } else if releases.deployed != nil {
                lines.append("origin/main is already what is running")
            } else {
                lines.append("the sentinel sent no release list")
            }
        } else {
            lines.append("Not yet deployed: \(releases.undeployed.count) "
                + "release\(releases.undeployed.count == 1 ? "" : "s")")
            let (kept, capNote) = AskBudget.cap(releases.undeployed, limit: limit,
                                                noun: "undeployed releases",
                                                totalsCoverAll: false)
            children += kept.map { release($0, label: nil) }
            note = capNote
        }
        if releases.truncated > 0 {
            lines.append("\(releases.truncated) older release"
                + "\(releases.truncated == 1 ? " was" : "s were")"
                + " dropped by the sentinel before this document reached the app, so they "
                + "are not here to read")
        }
        return AskFacts(heading: "Releases", lines: lines, children: children, note: note)
    }

    /// The in-flight (or just-finished) deploy: its phase, its verdict, its reason, and the
    /// tail of its log.
    static func deployProgress(_ record: DeployStatusDocument.DeployRecord,
                               logLines: Int = AskBudget.maxListItems) -> AskFacts {
        var lines = [
            "\(record.resultHealth.word) · "
                + (record.inFlight ? "in flight, phase \(record.phase)"
                                   : "finished: \(record.result ?? "finished")"),
            "asked for \(record.gitRef)"
                + (record.sha.map { ", resolved to \(OpsFormat.shortSha($0))" } ?? ""),
        ]
        if let reason = record.reason, !reason.isEmpty { lines.append("reason: \(reason)") }
        var note: String?
        var children: [AskFacts] = []
        if !record.logTail.isEmpty {
            // The TAIL, so the newest lines survive the cap: a build's last ten lines are
            // where the failure is, and the first ten are the same every time.
            let kept = Array(record.logTail.suffix(logLines))
            let dropped = record.logTail.count - kept.count
            children.append(AskFacts(heading: "Log tail (last \(kept.count) lines on screen)",
                                     lines: kept))
            if dropped > 0 {
                note = "\(dropped) earlier line\(dropped == 1 ? "" : "s") of the tail not "
                    + "listed here"
            }
        }
        return AskFacts(heading: "Deploy in progress", lines: lines,
                        children: children, note: note)
    }

    /// The Deploy card whole: what is running, what `origin/main` is, whether the view of
    /// it is stale, what the button decided, and the release notes.
    static func deploy(_ doc: DeployStatusDocument) -> AskFacts {
        var lines = [
            "Running: \(doc.running.version ?? "unknown") · "
                + OpsFormat.shortSha(doc.running.sha),
            "origin/main: \(doc.originMain.version ?? "unknown") · "
                + "\(OpsFormat.shortSha(doc.originMain.sha)) · CI "
                + "\(doc.originMain.ci) (\(doc.originMain.ciHealth.word))",
        ]
        if let detail = doc.originMain.ciDetail, !detail.isEmpty {
            lines.append("CI detail: \(detail)")
        }
        if doc.originMain.isStale {
            // STALENESS TRAVELS WITH THE READING, not just in the card's title. A cached
            // answer presented to the agent as a current one is the one way this snapshot
            // could mislead about the machine.
            lines.append("THIS VIEW OF origin/main IS STALE: "
                + (doc.originMain.staleReason ?? "the sentinel did not say why")
                + " — the version, sha, CI verdict and release list below may all be out of date")
        }
        let availability = DeployAvailability.decide(doc)
        lines.append("Deploy button: "
            + (availability.isReady
               ? "offered"
               : "not offered — \(availability.reason ?? "no reason given")"))

        var children: [AskFacts] = []
        if let releases = doc.releases {
            children.append(Self.releases(releases))
        } else {
            children.append(AskFacts(
                heading: "Releases",
                lines: ["this sentinel predates the release-notes block, so the card shows "
                    + "no release list — which is routine, not a fault: a deploy replaces "
                    + "the bridge, not the sentinel"]))
        }
        if let record = doc.deploy { children.append(deployProgress(record)) }
        return AskFacts(heading: "Deploy", lines: lines, children: children)
    }

    // MARK: - Schedule

    /// One schedule job, carrying the same detail lines the row prints.
    static func scheduleRow(_ member: ScheduleChain.Member, bridgeTz: String?) -> AskFacts {
        let row = member.row
        var lines = [
            "\(OpsFormat.outcomeHealth(row.lastOutcome).word) · "
                + "\(row.kind.isEmpty ? (row.isHead ? "head" : "link") : row.kind) · \(row.whenLabel)",
            "enabled: \(row.enabled ? "yes" : "no")"
                + (row.enabledConfig.map { " (the config file says \($0 ? "yes" : "no"))" } ?? ""),
            "days: \(row.resolvedDays)",
            "profiles: \((row.profiles ?? ["home", "away"]).joined(separator: ", "))",
            "next: \(OpsFormat.inBothZones(row.nextFireMs, bridgeTz: bridgeTz))",
        ]
        if let outcome = row.lastOutcome {
            let last = [outcome, OpsFormat.duration(ms: row.lastDurationMs)]
                .compactMap { $0 }.joined(separator: " · ")
            lines.append("last: \(last)")
        }
        if let reason = row.lastReason, !reason.isEmpty { lines.append("reason: \(reason)") }
        if let n = row.consecutiveFailures, n > 0 {
            // The streak, not just the last outcome: "failed" says last night, this says it
            // was the sixth night running.
            lines.append("\(n) consecutive failures")
        }
        lines.append("output: \(row.outputLabel)")
        if let from = row.promotedFrom { lines.append("promoted: took the clock slot of \(from)") }
        if let ov = row.override {
            lines.append("override: \(OpsFormat.overrideLine(ov))")
        }
        if let retry = row.retryDueMs {
            lines.append("retry due: \(OpsFormat.inBothZones(retry, bridgeTz: bridgeTz))")
        }
        if row.running == true { lines.append("running right now") }
        return AskFacts(heading: row.id, lines: lines)
    }

    static func scheduleChain(_ chain: ScheduleChain, bridgeTz: String?) -> AskFacts {
        AskFacts(heading: chain.members.count > 1 ? "\(chain.id) chain" : chain.id,
                 children: chain.members.map { scheduleRow($0, bridgeTz: bridgeTz) })
    }

    // MARK: - Away profile

    static func profile(_ p: ProfileDocument?, error: String?, zone: TimeZone) -> AskFacts {
        guard let p else {
            return AskFacts(heading: "Away mode",
                            lines: [error.map { "could not read the profile: \($0)" }
                                    ?? "the bridge has not answered the profile yet"])
        }
        var lines = [
            "Profile: \(p.name)",
            "Deriving dates in: \(p.tz ?? "unknown")",
            "The Studio's own zone: \(p.processTz ?? "unknown")",
            "A period is in force: \(p.isAway ? "yes" : "no")",
        ]
        if let until = p.until {
            lines.append((p.isAway ? "Until: " : "Last period ended: ")
                + OpsFormat.dayAndTime(until, in: zone))
        }
        if let since = p.since {
            lines.append("Since: \(OpsFormat.dayAndTime(since, in: zone))")
        }
        if !p.note.isEmpty { lines.append("Note (rides on every prompt): \(p.note)") }
        if !p.isAway, p.untilMs != nil {
            // The stored-but-lapsed case, said out loud here as it is on screen.
            lines.append("an away period is on record but is no longer in force")
        }
        if let error, !error.isEmpty { lines.append("last read error: \(error)") }
        return AskFacts(heading: "Away mode", lines: lines)
    }
}
