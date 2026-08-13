import Foundation
import JesseNetworking

// Every derived fact the Today screen renders, as pure functions over the wire
// types. Nothing here touches the network, the clock or a view; `TodayDashboardModel`
// holds the state and this decides what that state MEANS. Keeping the two apart is
// what makes the interesting behavior — an optimistic tap, a move that re-keys an
// item — testable without a server and without a view hierarchy.
//
// All of it is `nonisolated`. The target's default isolation is already nonisolated,
// but these are written out because it is a deliberate property rather than an
// accident of a package setting: the counts are read from the MainActor views AND
// from off-main callers (the tab badge computed while a turn's context is being
// built), and a MainActor default would silently make the second an await.

// MARK: - The optimistic overlay

/// The local, not-yet-confirmed state layered over the server's snapshot so a tap
/// responds instantly.
///
/// Every field is keyed by ITEM OR REPORT ID, which is exactly why `rekey(from:to:)`
/// exists: an id is a content hash over `(sectionName, lead, addedDate)`, so an item
/// that crosses a section boundary comes back from the bridge under a different id
/// and every entry here would otherwise be orphaned — a "ghost" of state pointing at
/// a row that no longer exists, and a checkbox that springs back open.
public struct TodayOptimism: Equatable, Sendable {
    /// Checkbox states the user set but the server has not confirmed.
    public var checks: [String: Bool] = [:]
    /// Evidence typed alongside a check, shown under the row until the server
    /// echoes back its own `appCompleted`.
    public var evidence: [String: String] = [:]
    /// Moves in flight, applied to the rendered order so the row travels under the
    /// finger rather than after the round trip.
    public var moves: [String: TodayMoveOp] = [:]
    /// Items the server answered `410` for: gone from the file, so gone from the
    /// screen, without waiting for the next fetch to stop returning them.
    public var removed: Set<String> = []
    /// Report rows glanced at locally, so the unseen dot clears on tap.
    public var seen: Set<String> = []
    /// Postponements the user set but the server has not confirmed, so the badge
    /// drops on the tap rather than after the round trip. `false` is a real entry:
    /// it is "bring this back to today", not the absence of a claim.
    public var deferrals: [String: Bool] = [:]

    public init(checks: [String: Bool] = [:], evidence: [String: String] = [:],
                moves: [String: TodayMoveOp] = [:], removed: Set<String> = [],
                seen: Set<String> = [], deferrals: [String: Bool] = [:]) {
        self.checks = checks
        self.evidence = evidence
        self.moves = moves
        self.removed = removed
        self.seen = seen
        self.deferrals = deferrals
    }

    public var isEmpty: Bool {
        checks.isEmpty && evidence.isEmpty && moves.isEmpty && removed.isEmpty
            && seen.isEmpty && deferrals.isEmpty
    }

    /// Carry every entry keyed `old` over to `new`, leaving nothing behind.
    ///
    /// The `removeValue` / re-insert shape is the point: an entry left under the old
    /// id would keep matching nothing forever, and — for `moves` in particular —
    /// would keep re-applying a move that already happened, so the row would render
    /// in the destination section twice over. Overwrites whatever sits at `new`,
    /// because the server's answer is the newer truth about that identity.
    public mutating func rekey(from old: String, to new: String) {
        guard old != new else { return }
        if let v = checks.removeValue(forKey: old) { checks[new] = v }
        if let v = evidence.removeValue(forKey: old) { evidence[new] = v }
        if let v = moves.removeValue(forKey: old) { moves[new] = v }
        if let v = deferrals.removeValue(forKey: old) { deferrals[new] = v }
        if removed.remove(old) != nil { removed.insert(new) }
        if seen.remove(old) != nil { seen.insert(new) }
    }

    /// Forget everything about one id — what a confirmed round trip does, since the
    /// server's snapshot now carries the truth the overlay was standing in for.
    public mutating func settle(_ id: String) {
        checks.removeValue(forKey: id)
        evidence.removeValue(forKey: id)
        moves.removeValue(forKey: id)
        deferrals.removeValue(forKey: id)
    }
}

public enum TodaySemantics {

    // MARK: - Rendering the overlay

    /// The snapshot as the screen should draw it: the server's document with the
    /// local overlay applied and the counts recomputed.
    ///
    /// Order matters. Removals first (a removed item must not then be moved), then
    /// checks and evidence (which change what a row says, not where it is), then
    /// moves (which change order), then a recount over the result — so the tab badge
    /// and the section headers agree with the rows actually on screen.
    public nonisolated static func display(_ snapshot: TodaySnapshot,
                                           applying overlay: TodayOptimism) -> TodaySnapshot {
        guard !overlay.isEmpty else { return snapshot }
        var out = snapshot
        out.leadItems = out.leadItems
            .filter { !overlay.removed.contains($0.id) }
            .map { applyItemOverlay($0, overlay) }
        out.sections = out.sections.map { section in
            var s = section
            s.items = s.items
                .filter { !overlay.removed.contains($0.id) }
                .map { applyItemOverlay($0, overlay) }
            s.reports = s.reports
                .filter { !overlay.removed.contains($0.id) }
                .map { report in
                    guard overlay.seen.contains(report.id), !report.seen else { return report }
                    var r = report
                    r.seen = true
                    return r
                }
            return s
        }
        out = applyMoves(out, overlay.moves)
        out.counts = counts(out)
        return out
    }

    /// One item with its pending check, evidence and postponement folded in.
    private nonisolated static func applyItemOverlay(_ item: TodayItem,
                                                     _ overlay: TodayOptimism) -> TodayItem {
        var it = item
        if let checked = overlay.checks[item.id] {
            it.checked = checked
            // An optimistic UNCHECK must also drop the sub-line the server still
            // reports, or the row would read "completed at 09:30" with an empty box.
            if !checked { it.appCompleted = nil }
        }
        if let note = overlay.evidence[item.id], !note.isEmpty {
            it.appCompleted = TodayAppCompleted(at: it.appCompleted?.at, evidence: note)
        }
        if let deferred = overlay.deferrals[item.id] { it.deferred = deferred }
        // DONE BEATS POSTPONED. A row cannot claim both: "I set this aside for
        // today" and "I did it" are answers to the same question, and the second
        // one supersedes the first. Stated here, as a rendering rule, rather than
        // by having the check endpoint reach into the defer store — the store is
        // still holding a decision about today, and a row that is un-ticked is a
        // row whose postponement was never withdrawn.
        if it.checked { it.deferred = false }
        return it
    }

    // MARK: - Optimistic moves

    /// Apply every in-flight move to the document's order.
    ///
    /// The item keeps its OLD id throughout: the new one is a hash the client cannot
    /// compute without re-implementing the bridge's lead normalization, and guessing
    /// it would be a second source of truth for identity. The row therefore renders
    /// in its destination under the id the client already knows, and the id only
    /// changes when the server's own snapshot arrives.
    nonisolated static func applyMoves(_ snapshot: TodaySnapshot,
                                       _ moves: [String: TodayMoveOp]) -> TodaySnapshot {
        guard !moves.isEmpty else { return snapshot }
        var out = snapshot
        // Deterministic order, so two pending moves never depend on dictionary
        // iteration order for their result.
        for id in moves.keys.sorted() {
            guard let op = moves[id] else { continue }
            out = applyMove(out, id: id, op: op)
        }
        return out
    }

    private nonisolated static func applyMove(_ snapshot: TodaySnapshot, id: String,
                                              op: TodayMoveOp) -> TodaySnapshot {
        // The lead block is structurally immutable — the bridge answers `409` for any
        // op on it — so an optimistic move of a lead item would always be reverted.
        guard let from = snapshot.sections.firstIndex(where: { $0.items.contains { $0.id == id } }),
              let index = snapshot.sections[from].items.firstIndex(where: { $0.id == id })
        else { return snapshot }

        var out = snapshot
        switch op {
        case .up:
            guard index > 0 else { return snapshot }
            out.sections[from].items.swapAt(index, index - 1)
        case .down:
            guard index + 1 < out.sections[from].items.count else { return snapshot }
            out.sections[from].items.swapAt(index, index + 1)
        case .topOfSection:
            guard index > 0 else { return snapshot }
            let item = out.sections[from].items.remove(at: index)
            out.sections[from].items.insert(item, at: 0)
        case .toDoNow:
            // The bridge picks the FIRST section whose name STARTS WITH "Do Now" —
            // matched the same way here so the optimistic landing and the real one are
            // the same section, including for a heading like "Do Now (today)".
            guard let to = out.sections.firstIndex(where: { $0.name.hasPrefix("Do Now") })
            else { return snapshot }
            if to == from && index == 0 { return snapshot }
            out = splice(out, from: from, at: index, to: to)
        case .toSection(let name):
            // An EXACT name here too, because that is how the bridge resolves it: the
            // day file carries both a `Do Now` and a `Do Now (carried, owed replies
            // and decisions)`, and a prefix match would land the row optimistically in
            // one section and really in the other.
            guard let to = out.sections.firstIndex(where: { $0.name == name }), to != from
            else { return snapshot }
            out = splice(out, from: from, at: index, to: to)
        }
        return out
    }

    /// Lift one item out of `from` and put it at the top of `to`, rewriting its
    /// section name.
    ///
    /// Shared by the two ops that cross a boundary, because the name rewrite is the
    /// part that is easy to forget and expensive to get wrong: the section name is
    /// part of the item's own identity, so keeping the stale one would make the
    /// later re-key match by section rather than by the `(lead, addedDate)` pair
    /// that actually survives a move.
    private nonisolated static func splice(_ snapshot: TodaySnapshot, from: Int, at index: Int,
                                           to: Int) -> TodaySnapshot {
        var out = snapshot
        var item = out.sections[from].items.remove(at: index)
        item.sectionName = out.sections[to].name
        out.sections[to].items.insert(item, at: 0)
        return out
    }

    // MARK: - Re-keying after a move

    /// Find `item` in the snapshot the server answered a move with, and return the id
    /// it now lives under.
    ///
    /// **Identity after a move, not the id.** An id hashes `(sectionName, lead,
    /// addedDate)`; a cross-section move changes the first, so the id is precisely the
    /// thing that did NOT survive. What did survive is the pair `(lead, addedDate)` —
    /// the move splices bytes and rewrites nothing — so that is what this matches on.
    ///
    /// `knownIds` is every id the client saw BEFORE the move. When two items in the
    /// destination share a lead and an Added date the bridge disambiguates them
    /// positionally (`…-2`, `…-3`), so several rows can match; preferring one whose id
    /// is new is what stops the re-key from landing on a sibling that was already
    /// there. Falling back to an unchanged id covers the ops that do not cross a
    /// section, where nothing was ever re-keyed.
    public nonisolated static func rekeyed(_ item: TodayItem, in snapshot: TodaySnapshot,
                                           excluding knownIds: Set<String>) -> String? {
        let matches = snapshot.allItems.filter {
            $0.lead == item.lead && $0.addedDate == item.addedDate
        }
        if let fresh = matches.first(where: { !knownIds.contains($0.id) }) { return fresh.id }
        if let same = matches.first(where: { $0.id == item.id }) { return same.id }
        return matches.first?.id
    }

    // MARK: - Counts

    /// Recount a snapshot from the items and reports it actually holds. The bridge
    /// sends its own tally, but the moment an overlay is applied that tally describes
    /// a document nobody is looking at.
    public nonisolated static func counts(_ snapshot: TodaySnapshot) -> TodayCounts {
        let items = snapshot.allItems
        let done = items.filter(\.checked).count
        return TodayCounts(open: items.count - done,
                           done: done,
                           reportsUnseen: snapshot.allReports.filter { !$0.seen }.count)
    }

    /// **What "open" means on this screen**: not done, and not set aside for today.
    ///
    /// One predicate rather than the same two clauses written at each call site,
    /// because the tab badge and every section header have to agree about it — the
    /// moment a header says 6 and the badge says 4, the user is reasoning about a
    /// number nobody defined.
    public nonisolated static func isOpen(_ item: TodayItem) -> Bool {
        !item.checked && !item.deferred
    }

    /// **Whether a row reads as postponed** — deferred, and not done.
    ///
    /// DONE BEATS POSTPONED, stated once so every reader of the rule agrees. The
    /// overlay pass already collapses the pair for a tap made on this device, but a
    /// snapshot can arrive carrying both from a SECOND device (postponed here,
    /// ticked off there), and a row struck through as done while also wearing a
    /// "Postponed" chip is two answers to one question.
    public nonisolated static func isPostponed(_ item: TodayItem) -> Bool {
        item.deferred && !item.checked
    }

    /// Open items in one section: unchecked, and not postponed.
    public nonisolated static func openCount(in section: TodaySection) -> Int {
        section.items.filter(isOpen).count
    }

    /// Postponed items in one section — the tally a header appends to its open
    /// count, so the rows set aside are accounted for rather than silently missing
    /// from the number.
    public nonisolated static func postponedCount(in section: TodaySection) -> Int {
        section.items.filter(isPostponed).count
    }

    /// Open items per section, keyed by section name, for the section headers.
    public nonisolated static func openCounts(_ snapshot: TodaySnapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: snapshot.sections.map { ($0.name, openCount(in: $0)) })
    }

    /// **The badge set**: every open LEAD item, then the open items of the first
    /// `Do Now…` section, in the order the screen draws them.
    ///
    /// Not `counts.open`, which tallies the whole document: Done Today, the aging
    /// list and every briefing section carry task lines too, and a badge counting
    /// those would show a number nobody can act on and never reach zero. What the
    /// badge means is "things I said I would do today, still open" — the Do Now
    /// section plus the standing top-priority item that sits above every heading.
    ///
    /// Postponed rows are excluded, which is the whole point of postponing. Before
    /// it existed, the only way to clear a badge for work that was not going to
    /// happen today was to tick the item off — which is a lie, and one that
    /// `Close it at source` would then propagate into the project files.
    ///
    /// **This is the one definition of what the badge means.** `doNowOpenCount` is
    /// the size of this list and the badge-only view is its contents, so the number
    /// on the tab and the rows the filter shows have nothing to disagree about. A
    /// filter that re-derived the membership rule would be a second definition, and
    /// the second one is the one that drifts on the next change to the first.
    public nonisolated static func badgeItems(_ snapshot: TodaySnapshot) -> [TodayItem] {
        let doNow = snapshot.sections.first { $0.name.hasPrefix("Do Now") }
        return snapshot.leadItems.filter(isOpen) + (doNow?.items.filter(isOpen) ?? [])
    }

    /// Whether one item is part of what the badge counts.
    ///
    /// Asked of the SNAPSHOT rather than of the item alone, because membership is not
    /// a property an item carries: "the first section named `Do Now…`" is a fact about
    /// the document, and a day file holding both a `Do Now` and a `Do Now (carried)`
    /// has two sections whose items look alike and only one of which counts.
    public nonisolated static func countsTowardBadge(_ item: TodayItem,
                                                     in snapshot: TodaySnapshot) -> Bool {
        badgeItems(snapshot).contains { $0.id == item.id }
    }

    /// **The tab badge**, as a number: the size of the badge set.
    public nonisolated static func doNowOpenCount(_ snapshot: TodaySnapshot) -> Int {
        badgeItems(snapshot).count
    }

    /// Unseen glanceable rows — the dot on the briefing sections.
    public nonisolated static func unseenReportCount(_ snapshot: TodaySnapshot) -> Int {
        snapshot.allReports.filter { !$0.seen }.count
    }

    /// **The number on the tab.** Open Do Now work plus glanceable rows not yet seen.
    ///
    /// One function rather than a sum a view writes, because a tab badge is a single
    /// claim — "this many things want you" — and the moment its two halves are added
    /// up at the call site, each platform's shell owns a private definition of what
    /// the badge means and they drift. `doNowOpenCount` and `unseenReportCount` stay
    /// public because the section headers and the unseen dot need them separately;
    /// this is the only thing the tab itself should read.
    public nonisolated static func tabBadge(_ snapshot: TodaySnapshot) -> Int {
        doNowOpenCount(snapshot) + unseenReportCount(snapshot)
    }

    // MARK: - Row presentation

    /// The bold lead and the rest of an item's first line, split for rendering.
    ///
    /// The bridge already computed `lead` (bold segment, else first sentence, markdown
    /// stripped). What a row wants on top of that is the REMAINDER — the detail after
    /// the lead — so the lead can be set in semibold and the rest in body text without
    /// re-parsing markdown in a view. Continuation lines and the `(Added …)` trailer
    /// are deliberately excluded: they have their own places in the row.
    public nonisolated static func leadAndDetail(_ item: TodayItem) -> (lead: String, detail: String) {
        let firstLine = item.text.split(separator: "\n", maxSplits: 1,
                                        omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let body = strippedMarkdown(taskBody(firstLine))
        let lead = item.lead
        guard !lead.isEmpty, let range = body.range(of: lead) else {
            return (lead, lead.isEmpty ? body : "")
        }
        let detail = String(body[range.upperBound...])
        return (lead, trimmedDetail(detail))
    }

    /// The detail with its leading punctuation and its trailing bookkeeping trailer
    /// removed, so a row reads as a sentence rather than as the tail of one.
    private nonisolated static func trimmedDetail(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        while let first = out.first, ".:;,—–-".contains(first) {
            out.removeFirst()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return stripTrailers(out).trimmingCharacters(in: .whitespaces)
    }

    /// Drop a trailing `(Added …)` / `(updated …)` trailer — the same bookkeeping the
    /// bridge keeps out of a lead, kept out of the detail for the same reason: the
    /// row shows those dates in its caption, not mid-sentence.
    nonisolated static func stripTrailers(_ body: String) -> String {
        var s = body.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(")"), let open = s.lastIndex(of: "(") {
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            let bookkeeping = inner.hasPrefix("Added ") || inner.lowercased().hasPrefix("updated ")
            guard bookkeeping else { break }
            s = String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// A task line with its `* [ ] ` / `- [x] ` marker removed. A line that is not a
    /// task comes back unchanged.
    nonisolated static func taskBody(_ line: String) -> String {
        for marker in ["* ", "- "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count)
            guard rest.count >= 3, rest.first == "[" else { return line }
            let box = rest.prefix(3)
            guard box == "[ ]" || box == "[x]" || box == "[X]" else { return line }
            return String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Markdown decoration removed, keeping the words: `**bold**`, `*emphasis*`,
    /// `` `code` `` and `~~strike~~` markers go, `[[target|alias]]` becomes its alias,
    /// `[text](url)` becomes its text.
    ///
    /// A deliberate port of the bridge's `strip_markdown` rather than a call into it:
    /// the bridge already stripped the LEAD, and this strips the REST of the same line
    /// so the two halves of a row are shaped alike. Underscores are left alone for the
    /// bridge's reason — `snake_case` identifiers are all over this vault and
    /// `_emphasis_` is not a spelling it uses.
    nonisolated static func strippedMarkdown(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let c = rest.first {
            if rest.hasPrefix("[["), let close = rest.range(of: "]]") {
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
                out += (inner.split(separator: "|").last.map(String.init) ?? String(inner))
                    .trimmingCharacters(in: .whitespaces)
                rest = rest[close.upperBound...]
            } else if c == "[", let mid = rest.range(of: "]("),
                      let end = rest[mid.upperBound...].firstIndex(of: ")") {
                out += rest[rest.index(after: rest.startIndex)..<mid.lowerBound]
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**") || rest.hasPrefix("~~") {
                rest = rest.dropFirst(2)
            } else if c == "*" || c == "`" {
                rest = rest.dropFirst()
            } else {
                out.append(c)
                rest = rest.dropFirst()
            }
        }
        return out
    }

    /// The continuation lines of an item, minus the app's own `app-completed`
    /// sub-line (which the row renders as evidence, not as body text).
    public nonisolated static func continuationLines(_ item: TodayItem) -> [String] {
        item.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .map { strippedMarkdown($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && !$0.contains("app-completed") }
    }

    /// The `Added … · updated …` caption under a row, or nil when the item carries
    /// neither date.
    public nonisolated static func dateCaption(_ item: TodayItem) -> String? {
        var parts: [String] = []
        if let added = item.addedDate { parts.append("Added \(added)") }
        if let updated = item.updatedDate { parts.append("updated \(updated)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The evidence to show under a checked row: what the user just typed, else what
    /// the file already records.
    public nonisolated static func evidenceText(_ item: TodayItem,
                                                pending: String?) -> String? {
        if let pending, !pending.isEmpty { return pending }
        guard let note = item.appCompleted?.evidence, !note.isEmpty else { return nil }
        return note
    }

    // MARK: - Move availability

    /// Which move ops make sense for an item right now, so the menu offers only
    /// buttons that will do something.
    ///
    /// Mirrors the bridge's own no-op rules (`up` on the first item, `down` on the
    /// last, `top_of_section` on something already at the top all write nothing) and
    /// its one hard refusal: the standing lead item is structurally immovable, so it
    /// gets no menu at all rather than four buttons that each answer `409`.
    public nonisolated static func availableMoves(for item: TodayItem,
                                                  in snapshot: TodaySnapshot) -> [TodayMoveOp] {
        guard !item.isLeadItem,
              let section = snapshot.sections.first(where: { $0.name == item.sectionName }),
              let index = section.items.firstIndex(where: { $0.id == item.id })
        else { return [] }
        var ops: [TodayMoveOp] = []
        if index > 0 { ops.append(.up) }
        if index + 1 < section.items.count { ops.append(.down) }
        if index > 0 { ops.append(.topOfSection) }
        let doNow = snapshot.sections.first { $0.name.hasPrefix("Do Now") }
        if let doNow, !(doNow.name == section.name && index == 0) { ops.append(.toDoNow) }
        // Every OTHER section, in file order. Not filtered down to "sensible"
        // destinations, because there is no such judgement to make: the day file's
        // sections are the day's own structure, and which of them a piece of work
        // belongs in is exactly the thing only the user knows. The item's own
        // section is left out because moving to where you already are writes
        // nothing (the bridge treats it as a no-op) and reads as a broken button.
        ops += snapshot.sections
            .filter { $0.name != section.name }
            .map { .toSection($0.name) }
        return ops
    }

    /// The menu label for an op.
    ///
    /// A `toSection` op labels itself with the destination's FULL name, verbatim. A
    /// day file carries both a `Do Now` and a `Do Now (carried, owed replies and
    /// decisions)`; shortened or prettified, those become two menu entries that
    /// both read "Do Now" and the menu becomes unusable.
    public nonisolated static func label(for op: TodayMoveOp) -> String {
        switch op {
        case .up: return "Move up"
        case .down: return "Move down"
        case .topOfSection: return "Move to top"
        case .toDoNow: return "Move to Do Now"
        case .toSection(let name): return name
        }
    }

    /// The SF Symbol for an op.
    public nonisolated static func symbol(for op: TodayMoveOp) -> String {
        switch op {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .topOfSection: return "arrow.up.to.line"
        case .toDoNow: return "bolt"
        case .toSection: return "folder"
        }
    }

    /// The submenu heading the `toSection` ops are gathered under.
    public static let moveToSectionLabel = "Move to section"

    /// The SF Symbol for a report row's `kind`, defaulting to a neutral glyph so an
    /// unrecognized kind still renders.
    public nonisolated static func reportSymbol(kind: String) -> String {
        switch kind {
        case "currency": return "chart.line.uptrend.xyaxis"
        case "health": return "heart"
        case "cheatsheet": return "list.bullet.rectangle"
        case "philosophy": return "book"
        default: return "doc.text"
        }
    }
}
