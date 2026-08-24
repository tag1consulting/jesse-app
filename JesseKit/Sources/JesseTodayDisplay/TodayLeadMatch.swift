import Foundation
import JesseNetworking

/// **How a change survives the night.**
///
/// An item id is `sha256(section | normalized lead | added date)`, truncated — so the
/// morning rebuild keeps an id only when it re-emits the item with the same words, in
/// the same section, carrying the same Added date. Any of those three moving gives the
/// same task a different id, and a change captured yesterday then addresses nothing.
///
/// The id is still tried FIRST on replay (it is exact, and it is what the bridge takes),
/// and this is the fallback for the case the id cannot cover: the day rolled over and
/// the task came back. Matching on the WORDS is the only handle left, because the words
/// are the only part of a task the day file preserves across a rebuild by design.
///
/// ## What is normalized away, and why each one
///
/// The rule is deliberately narrow. A loose match would tick the wrong box, which is
/// worse than refusing — a refusal costs one re-tap and says so, a mis-match writes a
/// completion into the vault about work nobody did.
///
///  * **Case.** The morning routine re-cases leads (a carried item's sentence may start
///    a line where it previously did not). Case never distinguishes two real tasks.
///  * **Whitespace runs.** A rebuild re-wraps, and a lead lifted from a re-wrapped line
///    differs from yesterday's by a space. Collapsing runs to one is what makes those
///    the same string.
///  * **A trailing `(Added …)` / `(Added …, updated …)` trailer.** The parenthetical is
///    BOOKKEEPING the routine rewrites — an item carried into a new day is re-stamped —
///    and it is not part of what the task says. It is stripped only from the END, so a
///    parenthetical inside the sentence (which IS what the task says) is kept.
///
/// Nothing else. Punctuation, ordering, wording, and any change to the substance of the
/// sentence all mean "this is not the task I checked off", and the honest answer is the
/// refusal with the Tell-Jesse fallback beside it.
public enum TodayLeadMatch {

    /// One lead reduced to what a match compares.
    public nonisolated static func normalized(_ lead: String) -> String {
        let withoutTrailer = strippingAddedTrailer(lead)
        let collapsed = withoutTrailer
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Remove a trailing `(Added …)` bookkeeping parenthetical, if the lead ends in one.
    ///
    /// Scanned from the END with a nesting counter rather than matched with a regex over
    /// the whole string, so a lead containing its own parentheses ("Order the part
    /// (TC-4417) (Added 2026-03-01)") loses only the trailer.
    nonisolated static func strippingAddedTrailer(_ lead: String) -> String {
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else { return trimmed }
        var depth = 0
        var openIndex: String.Index?
        var index = trimmed.endIndex
        while index > trimmed.startIndex {
            index = trimmed.index(before: index)
            let character = trimmed[index]
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 {
                    openIndex = index
                    break
                }
            }
        }
        guard let openIndex else { return trimmed }
        let inner = trimmed[trimmed.index(after: openIndex)..<trimmed.index(before: trimmed.endIndex)]
        // Only a BOOKKEEPING trailer goes. "(Added 2026-03-01)" and
        // "(Added 2026-03-01, updated 2026-03-03)" are the two the parser emits; a
        // parenthetical that says anything else is the task's own words.
        guard inner.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("added ")
        else { return trimmed }
        return String(trimmed[trimmed.startIndex..<openIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether two leads name the same task.
    public nonisolated static func matches(_ a: String, _ b: String) -> Bool {
        let left = normalized(a)
        // An empty lead matches nothing, ever. The day file legitimately holds
        // `* [ ]` — a checkbox with no words — and every one of them would otherwise
        // match every other one.
        guard !left.isEmpty else { return false }
        return left == normalized(b)
    }

    /// **Re-find a captured change on a rebuilt day**, by words.
    ///
    /// Searches only items that are still OPEN, and that is the safety rule rather than
    /// an optimization: a replayed check whose task the morning already carried over as
    /// done has nothing to do, and re-ticking a ticked box would rewrite its
    /// `app-completed` stamp to the replay's time — overwriting a true record with a
    /// second one.
    ///
    /// Returns `nil` when the words appear MORE THAN ONCE among the open items. Two open
    /// tasks worded identically are indistinguishable to this rule, and guessing between
    /// them is exactly the mis-match it exists to prevent.
    public nonisolated static func resolve(lead: String,
                                           in snapshot: TodaySnapshot) -> TodayItem? {
        let candidates = snapshot.allItems.filter { !$0.checked && matches($0.lead, lead) }
        return candidates.count == 1 ? candidates.first : nil
    }
}
