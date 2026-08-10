import Foundation

// The two fixed prompts the Today tab sends on a fresh Tell thread, peers of
// `HealthNewDay.prompt`. Both wordings are LOAD-BEARING and frozen; a reword is a
// behavior change to the Studio-side agent, not an editorial choice.
//
// The property they exist to hold is SCOPE. The vault's morning routines are
// selected by what a turn's text says, so a prompt that merely describes a task can
// trip an unrelated routine on a keyword and rebuild the whole day file underneath a
// screen the user is reading. Each prompt therefore:
//
//   1. Names its own scope positively ("this one item only"), and
//   2. Names the routines it must NOT trigger, negatively and by name.
//
// (2) is why "start of day" appears in `TodayDiscuss` at all — and why it appears
// ONLY inside the negative-scope sentence. A test pins that: if the phrase ever
// migrates into the positive half of the instruction, keyword-based routing would
// read it as a request to run start-of-day and the item discussion would become a
// full morning rebuild.
//
// ISOLATION. This target compiles with `defaultIsolation(MainActor.self)` (it holds
// the @Model layer, which was authored against the app's MainActor default), so
// everything here would be MainActor-isolated by default. Both builders are marked
// `nonisolated` DELIBERATELY: they are pure string functions of their arguments, and
// their callers are not all on the main actor — a propagate prompt is built while a
// turn's body is being assembled off-main. Inheriting the default would make each of
// those an await for no reason, and would make these untestable from a plain
// synchronous test method.

/// "Discuss this item with me" — opens a conversation about one Today.md line
/// without letting it become a day rebuild.
public enum TodayDiscuss {
    /// Build the discuss prompt around one item's RAW markdown.
    ///
    /// `item` is `TodayItem.text` — the task line and its whole continuation block,
    /// links and `(Added …)` / `(updated …)` trailers included, verbatim. The agent
    /// needs the raw form rather than the display lead: the links are what it reads
    /// first, and the dates are how it tells a stale item from a fresh one.
    public nonisolated static func prompt(item: String) -> String {
        """
        Jeremy wants to discuss this Today.md item:

        \(item)

        Read the files it links first, then engage with his questions and clarifications. If the discussion changes the item (its priority, its scope, or whether it is done), update Today.md and the item's Dashboard or project home to match. Scope: this one item only. Do not run start of day, scanners, currency, or cheatsheets, and do not rebuild Today.md.
        """
    }
}

/// "I finished this — close it at source" — propagates one completed item out to
/// the project file and Dashboard it came from.
public enum TodayPropagate {
    /// The word that stands in for absent evidence, so the sentence reads the same
    /// either way and the agent is never handed an empty quotation to interpret.
    public nonisolated static let noEvidence = "none"

    /// Build the propagate prompt around one item's RAW markdown and the one line of
    /// evidence the user typed (or nothing).
    ///
    /// The two negative clauses are the safety of this prompt. "Do not close anything
    /// else" bounds the blast radius to one item; the roll-up clause exists because
    /// Today.md legitimately carries lines that SUMMARIZE many tasks ("four scanners
    /// and the workshop sweep"), and reading one of those as a completion would close
    /// every task it names at source in a single turn.
    public nonisolated static func prompt(item: String, evidence: String?) -> String {
        let note = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = (note?.isEmpty ?? true) ? noEvidence : note!
        return """
        Jeremy completed this Today.md item in the Jesse App and wants it propagated now:

        \(item)

        Evidence he gave: "\(given)". Close it at source: write the completion context and evidence into the linked project file as (completed YYYY-MM-DD: <evidence>), close or remove the matching Dashboard entry, keep the item checked in Today.md, move it to the Done section, and remove the app-completed sub-line. Do not close anything else, never treat a roll-up line that summarizes many tasks as a bulk close, and do not run any other routine.
        """
    }
}
