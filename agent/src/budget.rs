//! **Budgets** — the ceilings a turn stops at, and the deck that prices it.
//!
//! ---- ENFORCED BEFORE THE CALL, NEVER DURING ONE -----------------------------
//!
//! Every ceiling is checked BEFORE a provider call is made. An iteration that would exceed
//! one ends the turn with [`crate::turn::StopReason::Budget`] and whatever answer the turn
//! has produced so far.
//!
//! The rejected alternative was to abort mid-call on overrun. It is worse in every
//! direction: **the tokens are already bought** the moment the request is accepted, so
//! killing the stream saves nothing and throws away the output that was paid for; the
//! caller gets a truncated answer indistinguishable from a provider failure; and the
//! thread is left holding a half-streamed assistant message. Stopping before the call
//! means the ceiling is a bound on what is SPENT, not a bound on what is delivered.
//!
//! ---- THE TWO CEILINGS THAT NEED A PREDICTION --------------------------------
//!
//! `max_iterations`, `max_tool_calls` and `max_wall` are checked against what has already
//! happened, so "before the call" is exact. `max_input_tokens_per_turn` and
//! `max_cost_usd` are not: the size and price of the NEXT call are unknown until it is
//! made, so checking only what has been spent would let one final call sail past the
//! ceiling and report an overrun after the fact.
//!
//! So both are checked against a PREDICTION, and the prediction is the previous call's
//! own figure. That is sound for a specific reason: **a turn's message list only grows.**
//! Each iteration appends the assistant's message and its tool results and re-sends the
//! whole thread, so the next prompt is at least as large as the last one, and (on a fixed
//! deck) at least as expensive. Using the last call as a lower bound on the next makes
//! these ceilings bounds the loop stops BEFORE crossing rather than ones it notices after.
//!
//! It is deliberately conservative, and the cost is stated plainly: a turn can stop one
//! iteration earlier than a perfect oracle would. That is the correct direction for a
//! spend limit to be wrong in.
//!
//! `max_output_tokens_per_call` is not a stop condition at all — it is a CAP, applied to
//! the request's `max_output_tokens`. A ceiling that ended the turn because the model
//! wanted to write a long answer would be a strange thing to build; clamping is what the
//! caller means.

use std::fmt;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::provider::Usage;

/// The default iteration ceiling: 24 provider calls in one turn.
///
/// Enough for a genuinely multi-step task (search, read several documents, cross-check,
/// answer) and far below the point at which a loop is looping rather than working. A turn
/// that has called a provider two dozen times without finishing is not one iteration away
/// from success.
pub const DEFAULT_MAX_ITERATIONS: u32 = 24;

/// The default tool-call ceiling for one turn.
pub const DEFAULT_MAX_TOOL_CALLS: u32 = 40;

/// The default per-call output cap.
pub const DEFAULT_MAX_OUTPUT_TOKENS_PER_CALL: u32 = 8_192;

/// The default whole-turn input ceiling. Sized so a turn cannot silently re-send a growing
/// thread into a very large bill: at typical prompt sizes it is reached long before an
/// iteration ceiling would be.
pub const DEFAULT_MAX_INPUT_TOKENS_PER_TURN: u64 = 400_000;

/// Which ceiling stopped a turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Ceiling {
    Iterations,
    ToolCalls,
    InputTokens,
    Wall,
    Cost,
}

impl fmt::Display for Ceiling {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Ceiling::Iterations => "iterations",
            Ceiling::ToolCalls => "tool_calls",
            Ceiling::InputTokens => "input_tokens",
            Ceiling::Wall => "wall",
            Ceiling::Cost => "cost",
        })
    }
}

/// What one turn may spend.
#[derive(Debug, Clone, PartialEq)]
pub struct Budget {
    pub max_iterations: u32,
    pub max_tool_calls: u32,
    /// A CAP on each request's `max_output_tokens`, not a stop condition. See the module docs.
    pub max_output_tokens_per_call: u32,
    pub max_input_tokens_per_turn: u64,
    /// Wall clock for the whole turn, measured on [`crate::tools::Clock::since_start`].
    ///
    /// NO DEFAULT: it comes from the caller, because only the caller knows what it is
    /// waiting for. A bridge turn behind a phone's spinner and an overnight batch have
    /// wall budgets three orders of magnitude apart, and a library that picked one would
    /// be wrong for both.
    pub max_wall: Duration,
    /// A dollar ceiling. `None` — the default — means no cost cap, which is honest: with a
    /// zero price deck (the default) a cost cap would fire never or immediately depending
    /// on a number nobody set.
    pub max_cost_usd: Option<f64>,
}

impl Budget {
    /// The documented defaults, with the caller's wall budget.
    pub fn with_wall(max_wall: Duration) -> Self {
        Budget {
            max_iterations: DEFAULT_MAX_ITERATIONS,
            max_tool_calls: DEFAULT_MAX_TOOL_CALLS,
            max_output_tokens_per_call: DEFAULT_MAX_OUTPUT_TOKENS_PER_CALL,
            max_input_tokens_per_turn: DEFAULT_MAX_INPUT_TOKENS_PER_TURN,
            max_wall,
            max_cost_usd: None,
        }
    }
}

/// Dollars per million tokens, in the three rates the bridge's deck carries.
///
/// **THE SAME FIELD NAMES AS `bridge/src/config.rs`'s `PriceDeck`**, so D4 adopts it
/// rather than defining a second deck whose `cached_per_m` turns out to mean something
/// slightly different. A cost model that exists twice is a cost model that disagrees with
/// itself the first time a rate changes.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PriceDeck {
    pub in_per_m: f64,
    pub cached_per_m: f64,
    pub out_per_m: f64,
}

impl PriceDeck {
    /// A free model. The DEFAULT, deliberately: a made-up price is worse than a stated
    /// zero, because a zero is obviously not a bill and a plausible wrong number is not.
    pub const ZERO: PriceDeck = PriceDeck {
        in_per_m: 0.0,
        cached_per_m: 0.0,
        out_per_m: 0.0,
    };

    /// The dollar cost of one call's usage vector.
    ///
    /// Reads the [`Usage`] invariant exactly as documented: `input_tokens` EXCLUDES cache
    /// reads, so the three counts are added at their own rates rather than one being
    /// subtracted from another.
    ///
    /// **CACHE WRITES ARE PRICED AT THE INPUT RATE**, and that is an approximation with a
    /// reason. On the Anthropic wire a cache write costs about 1.25× input; the deck has
    /// three rates, not four. Adding a fourth would make this type stop being the bridge's
    /// deck, which is the one property it is here to have — and would put the divergence
    /// in the type D4 is meant to adopt. So the approximation is documented, it errs LOW
    /// by about a quarter of the cache-write component only, and the fourth rate belongs in
    /// whichever change is prepared to add it on both sides at once.
    pub fn cost_usd(&self, u: &Usage) -> f64 {
        let input = u.input_tokens.unwrap_or(0) as f64;
        let output = u.output_tokens.unwrap_or(0) as f64;
        let cache_read = u.cache_read_tokens.unwrap_or(0) as f64;
        let cache_write = u.cache_write_tokens.unwrap_or(0) as f64;
        ((input + cache_write) * self.in_per_m
            + cache_read * self.cached_per_m
            + output * self.out_per_m)
            / 1_000_000.0
    }
}

impl Default for PriceDeck {
    fn default() -> Self {
        PriceDeck::ZERO
    }
}

/// What a turn has spent so far. The loop owns one; [`check`](Spend::check) is what it asks
/// before each provider call.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Spend {
    /// Provider calls COMPLETED (not attempted — the provider layer's retries are one call).
    pub iterations: u32,
    pub tool_calls: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub cost_usd: f64,
    /// The previous call's total prompt tokens, the lower bound on the next call's. See the
    /// module docs for why the prediction is sound.
    pub last_call_input_tokens: u64,
    /// The previous call's cost, the lower bound on the next call's.
    pub last_call_cost_usd: f64,
}

impl Spend {
    /// Fold one completed call's usage in.
    pub fn record_call(&mut self, usage: &Usage, prices: &PriceDeck) {
        let input = usage.input_tokens.unwrap_or(0);
        let cache_read = usage.cache_read_tokens.unwrap_or(0);
        let cache_write = usage.cache_write_tokens.unwrap_or(0);
        self.iterations += 1;
        self.input_tokens += input;
        self.output_tokens += usage.output_tokens.unwrap_or(0);
        self.cache_read_tokens += cache_read;
        self.cache_write_tokens += cache_write;
        let cost = prices.cost_usd(usage);
        self.cost_usd += cost;
        // The whole PROMPT, not just the billed-at-input part: what the next call has to
        // send is the conversation, whether or not the host serves some of it from cache.
        self.last_call_input_tokens = input + cache_read + cache_write;
        self.last_call_cost_usd = cost;
    }

    /// The ceiling that would be exceeded by making another call now, if any.
    ///
    /// `elapsed` is the turn's monotonic age. Checked in a fixed order so that a turn which
    /// trips two ceilings at once reports the same one every time — a stop reason that
    /// varies run to run is a stop reason nobody can act on.
    pub fn check(&self, budget: &Budget, elapsed: Duration) -> Option<Ceiling> {
        if self.iterations >= budget.max_iterations {
            return Some(Ceiling::Iterations);
        }
        if self.tool_calls >= budget.max_tool_calls {
            return Some(Ceiling::ToolCalls);
        }
        if elapsed >= budget.max_wall {
            return Some(Ceiling::Wall);
        }
        // The two predicted ceilings. On the FIRST call both predictions are zero, so
        // neither can stop a turn before it has done anything — a budget of one token
        // still buys one call, which is the only behaviour that makes a "stop before you
        // exceed it" rule usable at all.
        if self
            .input_tokens
            .saturating_add(self.last_call_input_tokens)
            > budget.max_input_tokens_per_turn
        {
            return Some(Ceiling::InputTokens);
        }
        if let Some(max) = budget.max_cost_usd {
            if self.cost_usd + self.last_call_cost_usd > max {
                return Some(Ceiling::Cost);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage(input: u64, output: u64, cache_read: u64, cache_write: u64) -> Usage {
        Usage {
            input_tokens: Some(input),
            output_tokens: Some(output),
            cache_read_tokens: Some(cache_read),
            cache_write_tokens: Some(cache_write),
            provider_request_id: None,
        }
    }

    const DECK: PriceDeck = PriceDeck {
        in_per_m: 3.0,
        cached_per_m: 0.3,
        out_per_m: 15.0,
    };

    #[test]
    fn cost_reads_the_usage_invariant_as_documented() {
        // input EXCLUDES cache reads, so nothing is subtracted here.
        let c = DECK.cost_usd(&usage(1_000_000, 1_000_000, 1_000_000, 0));
        assert!((c - (3.0 + 15.0 + 0.3)).abs() < 1e-9, "got {c}");
        // A cache write is priced at the input rate — the documented approximation.
        let w = DECK.cost_usd(&usage(0, 0, 0, 1_000_000));
        assert!((w - 3.0).abs() < 1e-9, "got {w}");
        assert_eq!(
            PriceDeck::ZERO.cost_usd(&usage(1_000, 1_000, 1_000, 1_000)),
            0.0
        );
    }

    #[test]
    fn a_missing_count_is_zero_not_a_panic() {
        // `None` means the wire did not report it (the Chat wire has no cache-write field).
        let u = Usage::default();
        assert_eq!(DECK.cost_usd(&u), 0.0);
    }

    fn budget() -> Budget {
        Budget {
            max_iterations: 3,
            max_tool_calls: 5,
            max_output_tokens_per_call: 100,
            max_input_tokens_per_turn: 1_000,
            max_wall: Duration::from_secs(60),
            max_cost_usd: None,
        }
    }

    #[test]
    fn nothing_stops_the_first_call() {
        assert_eq!(Spend::default().check(&budget(), Duration::ZERO), None);
    }

    #[test]
    fn each_counted_ceiling_fires_at_its_number() {
        let mut s = Spend {
            iterations: 3,
            ..Default::default()
        };
        assert_eq!(
            s.check(&budget(), Duration::ZERO),
            Some(Ceiling::Iterations)
        );
        s.iterations = 2;
        s.tool_calls = 5;
        assert_eq!(s.check(&budget(), Duration::ZERO), Some(Ceiling::ToolCalls));
        s.tool_calls = 0;
        assert_eq!(
            s.check(&budget(), Duration::from_secs(60)),
            Some(Ceiling::Wall)
        );
        assert_eq!(s.check(&budget(), Duration::from_secs(59)), None);
    }

    #[test]
    fn the_input_ceiling_stops_before_the_call_that_would_cross_it() {
        let mut s = Spend::default();
        // Two calls of 400 prompt tokens each: 800 spent, next predicted at 400 → 1200 > 1000.
        s.record_call(&usage(400, 10, 0, 0), &PriceDeck::ZERO);
        assert_eq!(
            s.check(&budget(), Duration::ZERO),
            None,
            "400 + 400 <= 1000"
        );
        s.record_call(&usage(400, 10, 0, 0), &PriceDeck::ZERO);
        assert_eq!(
            s.check(&budget(), Duration::ZERO),
            Some(Ceiling::InputTokens),
            "stops BEFORE the third call, with 800 spent — never after crossing 1000"
        );
        assert!(s.input_tokens <= 1_000);
    }

    #[test]
    fn the_prediction_counts_the_whole_prompt_including_cache_reads() {
        // A cached turn bills little input but SENDS the whole conversation; predicting
        // from `input_tokens` alone would let a 900-token cached prompt look like 50.
        let mut s = Spend::default();
        s.record_call(&usage(50, 10, 900, 0), &PriceDeck::ZERO);
        assert_eq!(s.last_call_input_tokens, 950);
    }

    #[test]
    fn the_cost_ceiling_is_predicted_the_same_way_and_is_off_by_default() {
        // A large input ceiling, so this test is about the COST ceiling and not about the
        // input one firing first — `check`'s fixed order would otherwise mask it.
        let mut b = Budget {
            max_input_tokens_per_turn: u64::MAX,
            ..budget()
        };
        assert_eq!(b.max_cost_usd, None);
        let mut s = Spend::default();
        s.record_call(&usage(1_000_000, 0, 0, 0), &DECK); // $3.00
        assert_eq!(s.check(&b, Duration::ZERO), None, "no cap, no stop");
        b.max_cost_usd = Some(5.0);
        assert_eq!(
            s.check(&b, Duration::ZERO),
            Some(Ceiling::Cost),
            "$3 spent + $3 predicted > $5 — stop before buying it"
        );
        assert!(s.cost_usd <= 5.0);
    }

    #[test]
    fn ceilings_are_checked_in_a_fixed_order() {
        // Every ceiling tripped at once: the answer must be the same one every time.
        let s = Spend {
            iterations: 99,
            tool_calls: 99,
            input_tokens: 99_999,
            last_call_input_tokens: 99_999,
            cost_usd: 99.0,
            last_call_cost_usd: 99.0,
            ..Default::default()
        };
        let b = Budget {
            max_cost_usd: Some(0.01),
            ..budget()
        };
        for _ in 0..8 {
            assert_eq!(
                s.check(&b, Duration::from_secs(999)),
                Some(Ceiling::Iterations)
            );
        }
    }
}
