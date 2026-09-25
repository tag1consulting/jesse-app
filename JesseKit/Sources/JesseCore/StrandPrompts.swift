import Foundation

// THE ONE PROMPT A STRAND SENDS, and a peer of `TodayDiscuss` in every respect that
// matters: frozen wording, Ask mode, its own scope named positively, and the routines it
// must not trip named negatively. Read the long note at the top of `TodayPrompts.swift`
// first; everything it says about scope, about the `{Owner}` placeholders the bridge
// renders, and about why these builders are `nonisolated` applies here unchanged.
//
// WHAT IS DIFFERENT ABOUT A STRAND. A Today item is a line; a strand is a NOTE, and the
// conversation about one goes both ways. Jeremy opens it either to ask where the work
// stands or to say what just happened to it: a run finished, a decision was made, a step
// was dropped or reordered. The second half is why this prompt says, in its own words,
// that an update he gives IS the instruction to record it in that note in the same turn.
// Without that sentence the Ask floor is read as forbidding the write, and the update he
// just gave is answered with a question about whether to save it.
//
// The permission it grants is bounded twice over, and both bounds are load-bearing:
//
//   1. ONE FILE. The note at `path` and nothing else. A strand note links drafts,
//      research and project files; a discussion that could edit those is a discussion
//      that can rewrite the Dashboard from a passing remark.
//   2. ONE REASON. An update Jeremy gave. Not tidying, not an audit, not a finding the
//      agent noticed while reading.

/// "Discuss this strand with me" — opens a two way conversation about one `Strands/` note,
/// in which an update Jeremy gives is recorded in that note and nothing else is touched.
public enum StrandDiscuss {

    /// Build the discuss prompt for one strand.
    ///
    /// `slug` is the note's file name without `.md` (`Jesse`), `title` its heading as the
    /// board shows it, and `path` the vault relative file (`Strands/Jesse.md`, or
    /// `Strands/archive/Shed.md` for a finished strand). All three, because they answer
    /// three different questions: the slug is how every other file in the vault REFERS to
    /// this strand, the title is what Jeremy just long pressed, and the path is the file
    /// to open.
    public nonisolated static func prompt(slug: String, title: String, path: String) -> String {
        """
        {Owner} wants to discuss the strand \(title), whose status note is the vault file at \(path). Other notes refer to this strand by its slug, \(slug).

        Read that note in full first, then, as far as the discussion needs them, the files its ## Drafts, ## Research and ## Vault sections link. A strand discussion goes both ways: {owner} may ask where this work stands, and {owner} may give an update on it, such as a run that finished, a decision made, or a step dropped or reordered. An update {owner} gives IS the instruction to record it in that note in the same turn, through the normal strand update procedure, without asking permission first. Write to that one note, for that one reason, and to no other file. Scope: this one strand only. Answer {owner_pronoun} questions about the work, and do not do task work {owner} has not asked for. Do not run start of day, scanners, currency, or cheatsheets, and do not start any other routine.
        """
    }
}
