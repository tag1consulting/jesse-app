import Foundation
import JesseAsk

// The SCOPE factories: one per thing on the Ops screens that can be asked about.
//
// Each is a thin composition over `OpsFacts` — a title, the reading, a subject noun, some
// starters, and a facts tree assembled from the unit serializers. That is the whole point
// of the split: an item names one unit block, a card names its rows' blocks, and the page
// names its cards'. Nothing here re-derives a value.
//
// WHY THE VIEW PASSES THE VALUES IN. Every factory takes the documents the view already
// holds rather than a model to re-read. A serializer that re-fetched would eventually
// disagree with the pixels the gesture was made on, and "the chat knows what you were
// looking at" is the entire feature. It is also what makes every one of these testable
// from a decoded fixture, with no view model and no network.

enum OpsAsk {

    // MARK: - The page

    /// The whole Bridge ops screen, for the toolbar's Ask entry.
    ///
    /// Every argument is a value `OpsView` already has on hand. Spelled out rather than
    /// taking the `OpsModel`: a factory that read the model would be MainActor-bound and
    /// untestable without one, and there is nothing here that the view does not already
    /// hold.
    static func page(status: SentinelStatusDocument?,
                     deploy: DeployStatusDocument?,
                     refreshError: String?,
                     isSentinelPaired: Bool,
                     verbs: [OpsAction],
                     lastVerb: OpsModel.VerbOutcome?,
                     isRunningVerb: Bool,
                     reading: OpsAskReading) -> AskContext {
        var children: [AskFacts] = []
        if !isSentinelPaired {
            children.append(AskFacts(lines: [
                "No sentinel is paired, so none of the cards below can be read. The screen "
                    + "is showing its pairing call to action instead.",
            ]))
        }
        if let refreshError, !refreshError.isEmpty {
            // The error line the screen shows ABOVE the cards, and the cards may be a stale
            // load behind it — which is the screen's own rule and has to reach the snapshot,
            // or the agent reads a failed refresh as a current reading.
            children.append(AskFacts(heading: "The last refresh failed",
                                     lines: [refreshError],
                                     note: "anything below may be from an earlier, "
                                         + "successful read rather than from now"))
        }
        if let status {
            children.append(OpsFacts.bridge(status.bridge))
            children.append(OpsFacts.services(status.services, rows: status.serviceRows))
            children.append(OpsFacts.tailscale(status.tailscale))
            children.append(OpsFacts.disk(status.disk))
            children.append(OpsFacts.git(status.git))
            children.append(OpsFacts.qmd(status.qmd))
            children.append(OpsFacts.watchdog(status.sentinel, now: reading.taken))
            children.append(OpsFacts.actions(verbs, last: lastVerb, isRunning: isRunningVerb))
            children.append(OpsFacts.ledger(status.ledgerRows, bridgeTz: nil))
        }
        if let deploy {
            children.append(OpsFacts.deploy(deploy))
        } else if isSentinelPaired {
            children.append(AskFacts(heading: "Deploy",
                                     lines: ["the sentinel has not answered the deploy card yet"]))
        }
        return AskContext(scope: .page, area: .ops, reading: reading,
                          title: "Bridge ops", subject: "this screen",
                          facts: AskFacts(children: children),
                          related: deployIdentifiers(deploy),
                          suggestedQuestions: OpsAskStarters.page)
    }

    // MARK: - The cards

    static func bridgeCard(_ status: SentinelStatusDocument?,
                           reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .bridge, reading: reading,
                   title: "Bridge · Ops", subject: "the Bridge card",
                   facts: OpsFacts.bridge(status?.bridge),
                   suggestedQuestions: OpsAskStarters.bridge)
    }

    static func servicesCard(_ status: SentinelStatusDocument?,
                             reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .services, reading: reading,
                   title: "Services · Ops", subject: "the Services card",
                   facts: OpsFacts.services(status?.services, rows: status?.serviceRows ?? []),
                   suggestedQuestions: OpsAskStarters.services)
    }

    static func serviceRow(_ row: ServiceRow, reading: OpsAskReading) -> AskContext {
        AskContext(scope: .item, area: .services, reading: reading,
                   title: "\(row.id) · Services", subject: "the \(row.id) service",
                   subjectKey: row.id,
                   facts: OpsFacts.service(row),
                   related: [row.label].compactMap { $0 },
                   suggestedQuestions: OpsAskStarters.service)
    }

    static func tailscaleCard(_ status: SentinelStatusDocument?,
                              reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .tailscale, reading: reading,
                   title: "Tailscale · Ops", subject: "the Tailscale card",
                   facts: OpsFacts.tailscale(status?.tailscale))
    }

    static func diskCard(_ status: SentinelStatusDocument?,
                         reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .disk, reading: reading,
                   title: "Disk · Ops", subject: "the Disk card",
                   facts: OpsFacts.disk(status?.disk),
                   suggestedQuestions: OpsAskStarters.disk)
    }

    static func gitCard(_ status: SentinelStatusDocument?,
                        reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .git, reading: reading,
                   title: "Git · Ops", subject: "the Git card",
                   facts: OpsFacts.git(status?.git),
                   suggestedQuestions: OpsAskStarters.git)
    }

    static func qmdCard(_ status: SentinelStatusDocument?,
                        reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .qmd, reading: reading,
                   title: "QMD · Ops", subject: "the QMD card",
                   facts: OpsFacts.qmd(status?.qmd))
    }

    static func watchdogCard(_ status: SentinelStatusDocument?,
                             reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .watchdog, reading: reading,
                   title: "Watchdog · Ops", subject: "the Watchdog card",
                   facts: OpsFacts.watchdog(status?.sentinel, now: reading.taken),
                   suggestedQuestions: OpsAskStarters.watchdog)
    }

    // MARK: - Actions

    static func actionsSection(verbs: [OpsAction], last: OpsModel.VerbOutcome?,
                               isRunning: Bool, reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .actions, reading: reading,
                   title: "Actions · Ops", subject: "these actions",
                   facts: OpsFacts.actions(verbs, last: last, isRunning: isRunning),
                   suggestedQuestions: ["What does each of these do?",
                                        "Which one would you press here?",
                                        "What does reloading the bridge environment break?"])
    }

    // MARK: - Ledger

    static func ledgerSection(_ rows: [LedgerRow], reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .ledger, reading: reading,
                   title: "Ledger · Ops", subject: "the ledger",
                   facts: OpsFacts.ledger(rows, bridgeTz: nil),
                   suggestedQuestions: OpsAskStarters.ledger)
    }

    static func ledgerRow(_ row: LedgerRow, reading: OpsAskReading) -> AskContext {
        // Identity is the job AND the instant: the same job appears many times in one
        // ledger, and two presses on two of its lines are two different readings.
        let key = "\(row.job ?? row.raw ?? "line")-\(row.atMs ?? UInt64(row.id))"
        return AskContext(scope: .item, area: .ledger, reading: reading,
                          title: "\(row.job ?? "ledger line") · Ledger",
                          subject: "this ledger line", subjectKey: key,
                          facts: OpsFacts.ledgerRow(row, bridgeTz: nil),
                          related: [row.jobId].compactMap { $0 },
                          suggestedQuestions: OpsAskStarters.ledgerRow)
    }

    // MARK: - Deploy

    static func deployCard(_ doc: DeployStatusDocument?, reading: OpsAskReading) -> AskContext {
        guard let doc else {
            return AskContext(scope: .section, area: .deploy, reading: reading,
                              title: "Deploy · Ops", subject: "the Deploy card",
                              facts: AskFacts(heading: "Deploy",
                                              lines: ["the sentinel has not answered the "
                                                  + "deploy card yet"]),
                              suggestedQuestions: OpsAskStarters.deploy)
        }
        return AskContext(scope: .section, area: .deploy, reading: reading,
                          title: "Deploy · Ops", subject: "the Deploy card",
                          facts: OpsFacts.deploy(doc),
                          related: deployIdentifiers(doc),
                          suggestedQuestions: OpsAskStarters.deploy)
    }

    /// One release block — the running one or any undeployed one, including the ones the
    /// card folded away behind its disclosure group.
    ///
    /// It carries the release AND the deploy state around it, because "what did this change"
    /// and "is this one of the ones I would get" are the same press: a release block on its
    /// own cannot say whether it is already running.
    static func release(_ r: DeployStatusDocument.Release, label: String?,
                        in doc: DeployStatusDocument?,
                        reading: OpsAskReading) -> AskContext {
        var children = [OpsFacts.release(r, label: label, limit: AskBudget.maxListItems)]
        if let doc {
            children.append(AskFacts(heading: "Where this sits", lines: [
                "running: \(doc.running.version ?? "unknown") · "
                    + OpsFormat.shortSha(doc.running.sha),
                "origin/main: \(doc.originMain.version ?? "unknown") · "
                    + OpsFormat.shortSha(doc.originMain.sha),
                r.sha == doc.running.sha
                    ? "this release IS what is running"
                    : "this release is NOT running yet",
            ]))
        }
        return AskContext(scope: .item, area: .deploy, reading: reading,
                          title: "\(r.version ?? OpsFormat.shortSha(r.sha)) · Release",
                          subject: "this release", subjectKey: r.sha,
                          facts: AskFacts(children: children),
                          related: [r.sha].filter { !$0.isEmpty },
                          suggestedQuestions: OpsAskStarters.release)
    }

    static func deployProgress(_ record: DeployStatusDocument.DeployRecord,
                               reading: OpsAskReading) -> AskContext {
        AskContext(scope: .item, area: .deploy, reading: reading,
                   title: "Deploy \(record.phase) · Ops", subject: "this deploy",
                   subjectKey: record.deployId,
                   facts: OpsFacts.deployProgress(record),
                   related: [record.deployId, record.sha ?? ""].filter { !$0.isEmpty },
                   suggestedQuestions: OpsAskStarters.deployProgress)
    }

    /// The shas and versions a chat can dig with — passed as identifiers, never as an
    /// instruction to go and fetch them.
    static func deployIdentifiers(_ doc: DeployStatusDocument?) -> [String] {
        guard let doc else { return [] }
        var out: [String] = []
        if let sha = doc.running.sha, !sha.isEmpty { out.append("running sha \(sha)") }
        if let v = doc.running.version, !v.isEmpty { out.append("running version \(v)") }
        if let sha = doc.originMain.sha, !sha.isEmpty { out.append("origin/main sha \(sha)") }
        if let v = doc.originMain.version, !v.isEmpty {
            out.append("origin/main version \(v)")
        }
        return out
    }

    // MARK: - Schedule

    static func schedulePage(_ doc: ScheduleDocument?, route: OpsConfiguration.Route,
                             loadError: String?, reading: OpsAskReading) -> AskContext {
        var children: [AskFacts] = []
        var head: [String] = ["fire and enable are \(route.label)"]
        if let doc {
            if let tz = doc.tz { head.append("bridge zone: \(tz)") }
            if let profile = doc.profile { head.append("profile: \(profile.name ?? "home")") }
            if doc.persistent == false {
                head.append("the scheduler's state is NOT being persisted, so every outcome "
                    + "below resets when the bridge restarts")
            }
            if let onReturn = doc.onReturn { head.append("on-return job: \(onReturn)") }
        }
        if let loadError, !loadError.isEmpty {
            head.append("the last read failed: \(loadError)")
        }
        children.append(AskFacts(heading: "The schedule", lines: head))
        let chains = doc?.chains ?? []
        let (kept, note) = AskBudget.cap(chains, noun: "chains", totalsCoverAll: false)
        children += kept.map { OpsFacts.scheduleChain($0, bridgeTz: doc?.tz) }
        if let note { children.append(AskFacts(lines: ["(\(note))"])) }
        if let invalid = doc?.invalid, !invalid.isEmpty {
            children.append(AskFacts(
                heading: "Disabled by validation — in the config file and NOT running",
                lines: invalid.map { "\($0.id): \($0.reason)" }))
        }
        return AskContext(scope: .page, area: .schedule, reading: reading,
                          title: "Schedule", subject: "this schedule",
                          facts: AskFacts(children: children),
                          suggestedQuestions: OpsAskStarters.schedule)
    }

    static func scheduleChain(_ chain: ScheduleChain, bridgeTz: String?,
                              reading: OpsAskReading) -> AskContext {
        AskContext(scope: .section, area: .schedule, reading: reading,
                   title: "\(chain.id) · Schedule", subject: "this chain",
                   subjectKey: "chain-\(chain.id)",
                   facts: OpsFacts.scheduleChain(chain, bridgeTz: bridgeTz),
                   suggestedQuestions: OpsAskStarters.schedule)
    }

    static func scheduleRow(_ member: ScheduleChain.Member, bridgeTz: String?,
                            reading: OpsAskReading) -> AskContext {
        AskContext(scope: .item, area: .schedule, reading: reading,
                   title: "\(member.row.id) · Schedule", subject: "this job",
                   subjectKey: member.row.id,
                   facts: OpsFacts.scheduleRow(member, bridgeTz: bridgeTz),
                   related: [member.row.lastOutputPath, member.row.lastJobId].compactMap { $0 },
                   suggestedQuestions: OpsAskStarters.scheduleRow)
    }

    // MARK: - Away mode

    static func awayPage(_ profile: ProfileDocument?, loadError: String?,
                         reading: OpsAskReading) -> AskContext {
        AskContext(scope: .page, area: .away, reading: reading,
                   title: "Away mode", subject: "this screen",
                   facts: OpsFacts.profile(profile, error: loadError, zone: reading.zone),
                   suggestedQuestions: OpsAskStarters.away)
    }
}
