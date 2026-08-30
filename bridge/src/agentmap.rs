use crate::*;

// ---- The bridge/agent seam --------------------------------------------------
//
// `agent/` is a standalone crate that depends on this one in NEITHER direction, and that is
// deliberate: the loop is written against its own vocabulary so it can be driven by a CLI, a
// test harness, or a future service that is not this bridge. The cost of that independence is
// that a handful of types are declared twice, and something has to say the two spellings mean
// the same thing.
//
// This module is that something, and it is deliberately TINY. Everything here is a total,
// lossless, order-preserving conversion between a bridge type and its agent counterpart. If a
// conversion in this file ever needs a policy decision — a default, a clamp, a fallback — it
// does not belong here: it belongs at the call site that knows what the policy is, and this
// file should stay the place a reader can check in thirty seconds that nothing was renamed
// out from under them.
//
// The three pairs, and why each is declared twice rather than shared:
//
//   * [`Capability`] ↔ [`Level`] — the levels a turn may be granted. The agent crate cannot
//     re-export the bridge's enum, and the bridge cannot make the agent's enum its own
//     without the dependency pointing the other way too.
//   * [`ShadowUsage`] ↔ [`TokenUsage`] — the four token counts. Field-identical, including
//     the `Option` on each: `None` and `0` mean different things on both sides (an absent
//     measurement is not a measured zero) and the conversion preserves that.
//   * [`PriceDeck`] ↔ [`AgentPrices`] — dollars per million tokens. The agent crate bills a
//     turn as it runs (it must, to enforce a cost budget mid-turn); the bridge bills it again
//     for the badge. Same three numbers, so the two answers agree by construction.

use jesse_agent::budget::PriceDeck as AgentPrices;
use jesse_agent::provider::TokenUsage;
use jesse_agent::tools::Level;

/// The bridge's capability, as the agent crate's level.
///
/// **THE MAPPING IS THE IDENTITY**, which is a decision both crates made on purpose and
/// wrote down: three names, the same three meanings, the same cumulative order. The
/// alternative considered and rejected on the agent side was a differently-shaped vocabulary
/// ("none / readonly / full"), which would have made this function a table somebody has to
/// keep true — and a level that means slightly different things on two sides of a boundary is
/// how a `Read` turn ends up holding a write tool.
///
/// Written as an exhaustive match with no wildcard so that a fourth capability is a compile
/// error here rather than a silent collapse onto one of the three.
impl From<Capability> for Level {
    fn from(c: Capability) -> Level {
        match c {
            Capability::Basic => Level::Basic,
            Capability::Read => Level::Read,
            Capability::Write => Level::Write,
        }
    }
}

/// The reverse, for the same reasons and with the same exhaustiveness.
///
/// It has one caller today — the containment battery, which asks the agent crate what a level
/// exposes and reports it in the bridge's vocabulary — and it exists mostly so the pair can
/// be round-tripped in a test. A one-directional conversion is a conversion nobody can check.
impl From<Level> for Capability {
    fn from(l: Level) -> Capability {
        match l {
            Level::Basic => Capability::Basic,
            Level::Read => Capability::Read,
            Level::Write => Capability::Write,
        }
    }
}

/// The agent's per-turn token vector, in the shape the cost badge already multiplies.
///
/// A pure rename of four fields. The `Option`s survive it: on both sides `None` means the
/// wire reported no such count and `0` means it reported zero, and folding those together
/// would make "this provider does not report cache writes" indistinguishable from "this call
/// wrote nothing to cache" — which is exactly the distinction an operator reads the usage
/// file to settle.
///
/// The one thing to notice is the field NAMES: the agent crate calls the last two
/// `cache_read_input_tokens` / `cache_creation_input_tokens`, the same Anthropic-shaped names
/// [`ShadowUsage`] uses, so this is a move rather than a translation. `agent/`'s own
/// `Usage` → `TokenUsage` conversion is where any wire's arithmetic was normalised; by the
/// time a vector reaches here it already satisfies the invariant `ShadowUsage::cost` assumes
/// (`input_tokens` EXCLUDES cache reads).
pub fn usage_from_agent(u: &TokenUsage) -> ShadowUsage {
    ShadowUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_input_tokens: u.cache_read_input_tokens,
        cache_creation_input_tokens: u.cache_creation_input_tokens,
    }
}

/// The bridge's price deck, as the agent crate's.
///
/// The agent loop needs a deck of its own because it enforces a COST budget mid-turn: it has
/// to know what the calls it has already made cost before deciding whether to make another.
/// Handing it the model's real deck is what makes that budget mean dollars rather than an
/// arbitrary unit — and it is what makes the loop's own `cost_usd` agree with the badge the
/// bridge computes afterwards from the same counts and the same three numbers.
pub fn prices_for_agent(deck: &PriceDeck) -> AgentPrices {
    AgentPrices {
        in_per_m: deck.in_per_m,
        cached_per_m: deck.cached_per_m,
        out_per_m: deck.out_per_m,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both directions, every variant, and the ORDER — which is the half a name-only check
    /// would miss. Both enums derive `Ord` and both orderings are load-bearing
    /// (`level.min(Capability::Write)` on one side, `Level::permits` on the other), so a
    /// swapped pair would keep every name and still make `Read` the most capable level.
    #[test]
    fn the_level_mapping_is_the_identity_in_both_directions_and_keeps_the_order() {
        let ours = [Capability::Basic, Capability::Read, Capability::Write];
        let theirs = [Level::Basic, Level::Read, Level::Write];
        for (c, l) in ours.iter().zip(theirs.iter()) {
            assert_eq!(Level::from(*c), *l);
            assert_eq!(Capability::from(*l), *c);
        }
        // Sorted independently on each side, then compared pairwise: if either enum is ever
        // reordered, these two sequences stop lining up.
        let mut ours_sorted = [Capability::Write, Capability::Basic, Capability::Read];
        ours_sorted.sort();
        let mut theirs_sorted = [Level::Write, Level::Basic, Level::Read];
        theirs_sorted.sort();
        for (c, l) in ours_sorted.iter().zip(theirs_sorted.iter()) {
            assert_eq!(Level::from(*c), *l, "the two orderings have drifted");
        }
    }

    /// The four counts move across intact, and an ABSENT count stays absent.
    #[test]
    fn usage_conversion_preserves_none_as_distinct_from_zero() {
        let full = TokenUsage {
            input_tokens: Some(120),
            output_tokens: Some(34),
            cache_read_input_tokens: Some(0),
            cache_creation_input_tokens: None,
        };
        let ours = usage_from_agent(&full);
        assert_eq!(ours.input_tokens, Some(120));
        assert_eq!(ours.output_tokens, Some(34));
        assert_eq!(
            ours.cache_read_input_tokens,
            Some(0),
            "a measured zero must not become an absence"
        );
        assert_eq!(
            ours.cache_creation_input_tokens, None,
            "an absence must not become a measured zero"
        );
    }

    /// The two decks bill one usage vector to the same cent, which is the whole point of
    /// handing the loop the model's real prices rather than a placeholder.
    #[test]
    fn both_decks_bill_one_usage_vector_identically() {
        let deck = PriceDeck {
            in_per_m: 3.0,
            cached_per_m: 0.3,
            out_per_m: 15.0,
        };
        let agent_deck = prices_for_agent(&deck);
        let u = TokenUsage {
            input_tokens: Some(1_000_000),
            output_tokens: Some(1_000_000),
            cache_read_input_tokens: Some(1_000_000),
            cache_creation_input_tokens: Some(0),
        };
        let ours = usage_from_agent(&u).cost_on(&deck);
        // The agent crate's own arithmetic over its own deck, on the same vector.
        let theirs = agent_deck.cost_usd(&jesse_agent::provider::Usage {
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            cache_read_tokens: u.cache_read_input_tokens,
            cache_write_tokens: u.cache_creation_input_tokens,
            reasoning_tokens: None,
            provider_request_id: None,
        });
        assert!(
            (ours - theirs).abs() < 1e-12,
            "the badge and the loop must agree: {ours} vs {theirs}"
        );
        assert!(
            (ours - 18.3).abs() < 1e-12,
            "3.00 + 15.00 + 0.30, got {ours}"
        );
    }
}
