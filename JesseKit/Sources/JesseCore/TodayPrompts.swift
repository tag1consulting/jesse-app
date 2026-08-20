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
// WHO THE PROMPT IS ABOUT. These wordings name the person the work belongs to, and
// that name is NOT the app's to know. It is deployment data, held on the bridge host
// in `jesse.local.toml` (or `JESSE_OWNER_NAME` / `JESSE_OWNER_PRONOUN`) and nowhere
// else, so a fresh clone belongs to whoever installed it. The prompts therefore carry
// the bridge's persona placeholders verbatim:
//
//   * `{Owner}` — the owner's name, capitalized for a sentence start;
//   * `{owner}` — the same name mid-sentence;
//   * `{owner_pronoun}` — the owner's POSSESSIVE pronoun ("their"/"his"/"her"/…).
//
// The bridge renders them once, while it assembles the turn, at the same point it
// renders its own Ask/Tell wrappers — so the wrapper and the body can never name two
// different people. A deployment that configures nothing degrades to the generic
// default the persona layer documents: "The user wants to discuss…", "their questions".
// Nothing here interpolates a name locally, and a placeholder that reaches the agent
// unrendered would mean the bridge did not build the turn.
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
        {Owner} wants to discuss this Today.md item:

        \(item)

        Read the files it links first, then engage with {owner_pronoun} questions and clarifications. If the discussion changes the item (its priority, its scope, or whether it is done), update Today.md and the item's Dashboard or project home to match. Scope: this one item only. Do not run start of day, scanners, currency, or cheatsheets, and do not rebuild Today.md.
        """
    }
}

/// How an ATTACHED context and the user's own first message become one turn.
///
/// A discussion does not fire when it is opened. Tapping Discuss used to send
/// `TodayDiscuss.prompt` immediately, which made Jeremy wait out a full turn before
/// he could type — backwards, because there is nothing for the agent to do until he
/// has said what his concern is. So the prompt is HELD against the empty thread and
/// travels with whatever he sends first.
///
/// Nothing about the framing is relaxed by that: the item markdown, its links and the
/// negative-scope sentence are all still in the turn, still ahead of anything he
/// typed. This is the composition rule the Mac and Watch Today tabs must use too — a
/// second spelling of it on another platform is a second definition of what an
/// item discussion is scoped to.
public enum TodayThreadContext {
    /// The label the typed message is filed under, so a multi-line message can never
    /// be read as more instruction.
    public nonisolated static let messageLabel = "{Owner}'s message:"

    /// Compose the held `context` with the user's first `typed` message.
    ///
    /// Context FIRST (scope before question), typed text last and labeled. Empty
    /// typed text is the explicit "just look at it" send and yields the context
    /// alone, byte for byte — never a dangling label with nothing under it.
    public nonisolated static func firstMessage(context: String, typed: String) -> String {
        let message = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return context }
        return """
        \(context)

        \(messageLabel)

        \(message)
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
    ///
    /// "Evidence he gave" keeps its SUBJECT pronoun. The persona layer renders a name
    /// and a POSSESSIVE pronoun and nothing else, so there is no placeholder that fits
    /// here, and spelling one would either change the current owner's rendered bytes or
    /// add a persona key every existing deployment would have to set. Left as a known
    /// gap rather than papered over.
    public nonisolated static func prompt(item: String, evidence: String?) -> String {
        let note = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = (note?.isEmpty ?? true) ? noEvidence : note!
        return """
        {Owner} completed this Today.md item in the Jesse App and wants it propagated now:

        \(item)

        Evidence he gave: "\(given)". Close it at source: write the completion context and evidence into the linked project file as (completed YYYY-MM-DD: <evidence>), close or remove the matching Dashboard entry, keep the item checked in Today.md, move it to the Done section, and remove the app-completed sub-line. Do not close anything else, never treat a roll-up line that summarizes many tasks as a bulk close, and do not run any other routine.
        """
    }
}

/// **"Process updates"** — every item ticked today, closed at source in ONE turn, and
/// the day file tidied behind them.
///
/// The batch peer of `TodayPropagate`, and deliberately a different prompt rather than
/// that one sent n times. Three reasons, all of them about what the vault ends up
/// looking like:
///
///   1. **One turn, one rewrite.** `Today.md` is a single file. Firing n propagations
///      means n turns racing to rewrite it, each with a stale idea of what the others
///      removed — the ETag path protects the APP's writes, not the agent's.
///   2. **The refill is a whole-file judgement.** "Top the day back up from the
///      Dashboard if it is now short" cannot be decided one item at a time; it is a
///      claim about the day that is only true once every closure has landed.
///   3. **Removal, not filing.** A single propagation keeps its item checked and moves
///      it to Done, because the user is still looking at that row. A batch is the end
///      of the day's bookkeeping, so the lines leave.
///
/// The negative clauses are carried over verbatim in spirit from `TodayPropagate` and
/// matter MORE here, because the blast radius is every ticked line at once: the list
/// below is exhaustive, roll-up lines are never bulk closes, and no other routine runs.
public enum TodayProcessUpdates {
    /// Build the batch prompt over the RAW markdown of every checked item.
    ///
    /// Raw for the same reason a single propagation is raw: the links are how the agent
    /// finds each item's home, and the `(Added …)` trailers are how it tells which of
    /// two similarly-worded lines it is looking at. The items are numbered so the
    /// instruction can say "the items listed above" and mean a countable set.
    public nonisolated static func prompt(items: [String]) -> String {
        let listed = items.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n\n")
        return """
        {Owner} checked these \(items.count) Today.md item\(items.count == 1 ? "" : "s") off in the Jesse App and wants them all processed now:

        \(listed)

        For each item listed above, in order: write the completion context and its evidence into the linked project file as (completed YYYY-MM-DD: <evidence>), and close or remove the matching Dashboard entry. Then remove those items from Today.md entirely, and if that leaves the day short, refill it from the Dashboard the way start of day would, adding the new items at the bottom. Scope: exactly the items listed above and nothing else. Never treat a roll-up line that summarizes many tasks as a bulk close. Do not run start of day, scanners, currency, or cheatsheets, and do not rebuild the rest of Today.md.
        """
    }
}
