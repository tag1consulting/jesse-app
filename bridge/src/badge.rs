//! The **model badge** — one display-only provenance line the bridge appends to
//! every delivered `POST /jesse/jesse` reply, naming which backend actually produced
//! the text the user is reading.
//!
//! It is derived from the bridge's OWN turn state (which branch produced the reply +
//! the configured/ambient model), NEVER from model output, and is display-only: it
//! is appended at the single point where the reply is finalized for delivery, and it
//! must never be written into a claude session, fed back into any child, committed to
//! the vault, or applied to the title endpoint.
//!
//! Exact strings (`·` is U+00B7):
//!   * `[local · vault · <model>]`               — a vault-QA local answer;
//!   * `[local · diet · <model> + hosted verify]` — a diet entry that ran the
//!     blocking verify (drop the `+ hosted verify` suffix on any future non-verify
//!     diet path);
//!   * `[local · emergency · <model>]`            — an EMERGENCY vault-QA answer served
//!     because the hosted backend was unavailable (Piece 4);
//!   * `[local · diet · <model> + verify queued]` — a diet entry captured locally and
//!     QUEUED for hosted verify because hosted was unavailable (Piece 4);
//!   * `[hosted · <model>]`                       — a hosted turn with an explicit
//!     ambient `ANTHROPIC_MODEL`, else `[hosted]`.
//!
//! A fallback turn badges the backend that actually produced the DELIVERED text
//! (hosted), never the one that tried first. The switch is `JESSE_MODEL_BADGE`
//! (`on|off`, default on → `cfg.model_badge`).

use crate::*;
use serde::{Deserialize, Serialize};

/// Which backend produced the delivered reply — the state the badge derives from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadgeSource {
    /// A hosted `run_claude_streaming` turn (including any diet/vault fallback).
    Hosted,
    /// A local diet entry that ran the blocking hosted verify.
    DietVerify,
    /// A local vault-QA answer.
    Vault,
    /// An EMERGENCY vault-QA answer (hosted was unavailable). Uses the vault-QA model.
    Emergency,
    /// A diet entry captured locally and QUEUED for hosted verify (hosted unavailable).
    /// Uses the diet model.
    DietQueued,
}

/// The active-model facts the HOSTED badge names, beyond the route: the global switch's
/// model id, whether it is a non-default model that has WRITE access (the Phase 2 marker),
/// and the turn's dollar cost when known. For a local route (vault/diet/emergency) the
/// badge is derived from `cfg` instead and this is ignored, so callers on those routes may
/// pass any value. Built once per turn in the handler from the resolved `ActiveModel`, the
/// turn's `usage`, and its price deck.
#[derive(Debug, Clone)]
pub struct HostedBadge {
    /// The active model id — what a hosted turn's badge names (`opus`, `glm-5.2`, …).
    pub model_id: String,
    /// A non-default model WITH write access (Phase 2) — adds the ` · write` marker so a
    /// writing non-Opus model is obvious at a glance. Always false for the ambient default.
    pub write_marked: bool,
    /// The turn's dollar cost (usage × the active model's price deck), or `None` when no
    /// usage was captured. A free (`local`) model resolves to `Some(0.0)` → `$0.0000`.
    pub cost_usd: Option<f64>,
}

impl HostedBadge {
    /// The ambient-default badge facts with no cost — used by tests and any path that
    /// does not carry an active-model resolution.
    pub fn opus() -> Self {
        HostedBadge {
            model_id: DEFAULT_MODEL_ID.to_string(),
            write_marked: false,
            cost_usd: None,
        }
    }
}

/// Format a dollar cost for a badge — fixed 4 decimals so a sub-cent turn still reads a
/// non-zero figure and a free (`local`) turn reads `$0.0000`.
pub fn format_cost_usd(cost: f64) -> String {
    format!("${cost:.4}")
}

/// Build the badge line for a delivered reply, or `None` when badges are off. Pure — the
/// local-route model strings come from `cfg` (the configured role backends); the HOSTED
/// route names the ACTIVE model (`hosted.model_id`), its write marker, and the turn's
/// cost. Never reads model output.
pub fn model_badge_line(cfg: &Config, source: BadgeSource, hosted: &HostedBadge) -> Option<String> {
    if !cfg.model_badge {
        return None;
    }
    let line = match source {
        BadgeSource::Vault => {
            let model = cfg
                .vaultqa_backend
                .as_ref()
                .map(|(_, _, m)| m.as_str())
                .unwrap_or("local");
            format!("[local · vault · {model}]")
        }
        BadgeSource::DietVerify => {
            let model = cfg
                .diet_backend
                .as_ref()
                .map(|(_, _, m)| m.as_str())
                .unwrap_or("local");
            format!("[local · diet · {model} + hosted verify]")
        }
        BadgeSource::Emergency => {
            // The emergency child IS the vault-QA child, so it badges the vault-QA model.
            let model = cfg
                .vaultqa_backend
                .as_ref()
                .map(|(_, _, m)| m.as_str())
                .unwrap_or("local");
            format!("[local · emergency · {model}]")
        }
        BadgeSource::DietQueued => {
            let model = cfg
                .diet_backend
                .as_ref()
                .map(|(_, _, m)| m.as_str())
                .unwrap_or("local");
            format!("[local · diet · {model} + verify queued]")
        }
        BadgeSource::Hosted => {
            // The hosted MAIN turn names the ACTIVE model the switch selected (`opus`,
            // `glm-5.2`, …), a ` · write` marker when a non-default model has write
            // access (Phase 2), and the turn's cost when known.
            let mut s = format!("[{}", hosted.model_id);
            if hosted.write_marked {
                s.push_str(" · write");
            }
            if let Some(cost) = hosted.cost_usd {
                s.push_str(" · ");
                s.push_str(&format_cost_usd(cost));
            }
            s.push(']');
            s
        }
    };
    Some(line)
}

/// Append a badge to a reply: a blank line, then the badge. ALWAYS appends exactly
/// one — it never inspects or dedupes the text, so a badge-shaped string already in
/// the model's own output can never suppress or duplicate the bridge's single badge.
pub fn append_badge(text: &str, badge: &str) -> String {
    format!("{text}\n\n{badge}")
}

/// Structured, display-only **provenance** for a delivered reply — the machine-readable
/// sibling of the text [`model_badge_line`]. Delivered alongside the text badge in BOTH
/// the poll result and the SSE `done` frame (never in the metrics log, never written to a
/// session, never on the title endpoint), so a client can render a native chip instead of
/// parsing the badge string out of the reply text.
///
/// It is present on a delivered reply EXACTLY when the text badge is appended (see
/// [`reply_provenance`]) — so an older client that ignores this field still reads the same
/// trailing badge in the text, and a newer client can strip that badge knowing the
/// provenance is authoritative. `badge` is byte-identical to what is appended to the text,
/// and `flags` mirror precisely what that badge (and, for `citations_unverified`, the
/// emergency [`CITATIONS_UNVERIFIED_WARNING`] prepended above it) encodes. The wire shape
/// is pinned by a shared fixture so the bridge and the app can't drift.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Provenance {
    /// Which backend produced the delivered text. The SAME vocabulary as the metrics
    /// [`MetricsRoute`], serialized to the same kebab strings (`hosted` | `vaultqa-local`
    /// | `diet-local` | `emergency-local`) — one route vocabulary across the bridge.
    pub route: MetricsRoute,
    /// The backend model that produced the reply, when known. On the hosted route this is
    /// the ACTIVE model the switch selected (`opus`, `glm-5.2`, …); on a local route it is
    /// the role backend's model. `None` (serialized `null`) when unknown.
    pub model: Option<String>,
    /// The turn's dollar cost — the hosted main turn's `usage` × the active model's price
    /// deck. `null`/absent on a local route (no main turn ran) and on an older bridge, so
    /// a client renders a cost only when present. `#[serde(default)]` keeps it
    /// additive-forward-compatible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    /// The exact text badge appended to the reply — byte-identical, so a client strips it
    /// from the display text by matching this string.
    pub badge: String,
    /// The flags the badge (and the emergency warning) encode.
    pub flags: ProvenanceFlags,
}

/// The boolean flags a reply's badge/warning encode. All three always serialize (never
/// skipped) so a client can read a stable shape. At most one of the first two is ever
/// true; `citations_unverified` is independent (emergency route only).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProvenanceFlags {
    /// A diet entry that ran the blocking hosted verify — the badge's `+ hosted verify`.
    pub hosted_verify: bool,
    /// A diet entry captured locally and QUEUED for a later hosted verify because hosted
    /// was unavailable — the badge's `+ verify queued`.
    pub verify_queued: bool,
    /// An EMERGENCY answer delivered WITHOUT a passing citation check — the reply text
    /// carries the prepended [`CITATIONS_UNVERIFIED_WARNING`] above the badge.
    pub citations_unverified: bool,
}

impl ProvenanceFlags {
    /// Derive the flags from the badge source. `hosted_verify`/`verify_queued` are
    /// implied by the source (they ARE the badge suffix); `citations_unverified` cannot
    /// be — it depends on the emergency turn's advisory validator — so it is passed in.
    fn from_source(source: BadgeSource, citations_unverified: bool) -> Self {
        ProvenanceFlags {
            hosted_verify: matches!(source, BadgeSource::DietVerify),
            verify_queued: matches!(source, BadgeSource::DietQueued),
            citations_unverified,
        }
    }
}

/// Build the structured provenance for a delivered reply, or `None` when the text badge
/// is NOT appended — so provenance is present on the payload EXACTLY when the badge is in
/// the text. Mirrors [`finalize_reply_badge`]'s append condition (badges on AND a
/// non-empty `Ok` reply) against the SAME pre-finalize `outcome`, so the two can never
/// disagree. `route`/`model` are the turn's resolved route + backend model (the same
/// values the metrics line records); `citations_unverified` is the emergency advisory
/// validator's verdict (always `false` off the emergency route).
pub fn reply_provenance(
    outcome: &Result<(String, Option<String>, Option<Directives>), ApiError>,
    cfg: &Config,
    route: MetricsRoute,
    source: BadgeSource,
    model: Option<String>,
    hosted: &HostedBadge,
    citations_unverified: bool,
) -> Option<Provenance> {
    // Present iff the badge is appended: an `Ok` reply with non-empty trimmed text AND
    // badges on. An empty (directive-only) reply and every error pass through with no
    // badge, so they carry no provenance either.
    let Ok((text, _, _)) = outcome else {
        return None;
    };
    if text.trim().is_empty() {
        return None;
    }
    let badge = model_badge_line(cfg, source, hosted)?;
    // Cost rides the provenance only on the hosted route (the only one whose usage the
    // main turn produced); a local route carries no cost figure.
    let cost_usd = match source {
        BadgeSource::Hosted => hosted.cost_usd,
        _ => None,
    };
    Some(Provenance {
        route,
        model,
        cost_usd,
        badge,
        flags: ProvenanceFlags::from_source(source, citations_unverified),
    })
}

/// Serialize an optional [`Provenance`] to the wire value used by BOTH the poll result
/// JSON and the SSE `done` frame, so the two paths are byte-consistent (mirrors
/// [`directives_to_value`]). `None` → JSON `null` (the app treats null/absent identically
/// and falls back to showing the reply text verbatim).
pub fn provenance_to_value(provenance: Option<&Provenance>) -> Value {
    match provenance {
        Some(p) => serde_json::to_value(p).unwrap_or(Value::Null),
        None => Value::Null,
    }
}

/// The single finalization seam: apply the badge to a completed turn's outcome just
/// before it lands in the job store. A no-op when badges are off, on an error
/// outcome, or on an EMPTY reply (a `JESSE_NEEDS_HEALTH` directive-only turn strips
/// to `""` and the app retries — a badge would make it non-empty and defeat that).
pub fn finalize_reply_badge(
    outcome: Result<(String, Option<String>, Option<Directives>), ApiError>,
    cfg: &Config,
    source: BadgeSource,
    hosted: &HostedBadge,
) -> Result<(String, Option<String>, Option<Directives>), ApiError> {
    let Some(badge) = model_badge_line(cfg, source, hosted) else {
        return outcome;
    };
    outcome.map(|(text, session_id, directives)| {
        let text = if text.trim().is_empty() {
            text
        } else {
            append_badge(&text, &badge)
        };
        (text, session_id, directives)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    fn cfg_on() -> Config {
        let mut cfg = test_config();
        cfg.model_badge = true;
        cfg.vaultqa_backend = Some(("http://u".into(), "tok".into(), "local-vaultqa".into()));
        cfg.diet_backend = Some(("http://u".into(), "tok".into(), "local-diet".into()));
        cfg
    }

    /// A `HostedBadge` for the hosted-route tests.
    fn hb(id: &str, write: bool, cost: Option<f64>) -> HostedBadge {
        HostedBadge {
            model_id: id.to_string(),
            write_marked: write,
            cost_usd: cost,
        }
    }

    #[test]
    fn badge_off_yields_no_line() {
        let mut cfg = cfg_on();
        cfg.model_badge = false;
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("opus", false, Some(0.01))),
            None
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Vault, &HostedBadge::opus()),
            None
        );
    }

    #[test]
    fn emergency_and_queued_badge_strings() {
        // Piece 4: the emergency ASK answer badges the vault-QA (emergency) model; a
        // queued diet Tell badges the diet model with the `+ verify queued` suffix. The
        // hosted-badge argument is ignored on a local route.
        let cfg = cfg_on();
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Emergency, &HostedBadge::opus()).unwrap(),
            "[local · emergency · local-vaultqa]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::DietQueued, &HostedBadge::opus()).unwrap(),
            "[local · diet · local-diet + verify queued]"
        );
    }

    #[test]
    fn local_route_badge_strings_are_unchanged_by_the_switch() {
        let cfg = cfg_on();
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Vault, &HostedBadge::opus()).unwrap(),
            "[local · vault · local-vaultqa]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::DietVerify, &HostedBadge::opus()).unwrap(),
            "[local · diet · local-diet + hosted verify]"
        );
    }

    #[test]
    fn hosted_badge_names_the_active_model_write_marker_and_cost() {
        let cfg = cfg_on();
        // Opus, no cost captured → bare model name.
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("opus", false, None)).unwrap(),
            "[opus]"
        );
        // Opus with a cost.
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("opus", false, Some(0.0123))).unwrap(),
            "[opus · $0.0123]"
        );
        // A switched hosted model, read-only.
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("glm-5.2", false, Some(0.0021)))
                .unwrap(),
            "[glm-5.2 · $0.0021]"
        );
        // A switched hosted model WITH write access (Phase 2 marker).
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("glm-5.2", true, Some(0.0021))).unwrap(),
            "[glm-5.2 · write · $0.0021]"
        );
        // A free local model reads $0.0000.
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, &hb("local", false, Some(0.0))).unwrap(),
            "[local · $0.0000]"
        );
    }

    #[test]
    fn append_badge_appends_exactly_one_even_when_text_contains_a_badge_shape() {
        // A badge-shaped string inside the model's own output must NOT produce a
        // second badge or suppress the bridge's one: append is blind and single.
        let text = "Here is your answer.\n\n[hosted · not-a-real-badge]\nMore text.";
        let out = append_badge(text, "[hosted]");
        assert_eq!(out, format!("{text}\n\n[hosted]"));
        // Exactly one bridge badge at the very end.
        assert!(out.ends_with("\n\n[hosted]"));
        assert_eq!(
            out.matches("\n\n[hosted]").count(),
            1,
            "one appended badge only"
        );
    }

    #[test]
    fn finalize_applies_the_badge_for_each_source() {
        let cfg = cfg_on();
        for (source, hosted, expected) in [
            (
                BadgeSource::Hosted,
                hb("opus", false, Some(0.02)),
                "[opus · $0.0200]",
            ),
            (
                BadgeSource::Vault,
                HostedBadge::opus(),
                "[local · vault · local-vaultqa]",
            ),
            (
                BadgeSource::DietVerify,
                HostedBadge::opus(),
                "[local · diet · local-diet + hosted verify]",
            ),
        ] {
            let out = finalize_reply_badge(
                Ok(("Reply body.".into(), Some("sess".into()), None)),
                &cfg,
                source,
                &hosted,
            )
            .unwrap();
            assert_eq!(out.0, format!("Reply body.\n\n{expected}"));
            assert_eq!(out.1.as_deref(), Some("sess"), "session id untouched");
        }
    }

    #[test]
    fn finalize_is_a_noop_when_off_or_on_error_or_empty() {
        // Off → text unchanged.
        let mut cfg = cfg_on();
        cfg.model_badge = false;
        let out = finalize_reply_badge(
            Ok(("body".into(), None, None)),
            &cfg,
            BadgeSource::Hosted,
            &hb("opus", false, Some(0.01)),
        )
        .unwrap();
        assert_eq!(out.0, "body", "badge off → reply unchanged");

        // On, but an EMPTY reply (a directive-only turn) is left empty so the app's
        // retry logic still fires.
        let cfg = cfg_on();
        let out = finalize_reply_badge(
            Ok(("".into(), None, None)),
            &cfg,
            BadgeSource::Hosted,
            &HostedBadge::opus(),
        )
        .unwrap();
        assert_eq!(out.0, "", "an empty reply must not be badged");

        // On, but an error outcome passes through unchanged.
        let err = finalize_reply_badge(
            Err((StatusCode::BAD_GATEWAY, "boom".into())),
            &cfg,
            BadgeSource::Hosted,
            &HostedBadge::opus(),
        );
        assert!(err.is_err(), "error outcomes are never badged");
    }

    // ---- Structured provenance (v2) ---------------------------------------

    fn ok(text: &str) -> Result<(String, Option<String>, Option<Directives>), ApiError> {
        Ok((text.into(), None, None))
    }

    struct RouteCase {
        route: MetricsRoute,
        source: BadgeSource,
        model: Option<&'static str>,
        hosted: HostedBadge,
        badge: &'static str,
        cost: Option<f64>, // provenance.cost_usd expected (hosted route only)
        flags: (bool, bool, bool), // (hosted_verify, verify_queued, citations_unverified)
    }

    #[test]
    fn provenance_present_matches_the_badge_for_each_route() {
        let cfg = cfg_on();
        let cases = [
            RouteCase {
                route: MetricsRoute::Hosted,
                source: BadgeSource::Hosted,
                model: Some("opus"),
                hosted: hb("opus", false, Some(0.0123)),
                badge: "[opus · $0.0123]",
                cost: Some(0.0123),
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::VaultqaLocal,
                source: BadgeSource::Vault,
                model: Some("local-vaultqa"),
                hosted: HostedBadge::opus(),
                badge: "[local · vault · local-vaultqa]",
                cost: None,
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::DietLocal,
                source: BadgeSource::DietVerify,
                model: Some("local-diet"),
                hosted: HostedBadge::opus(),
                badge: "[local · diet · local-diet + hosted verify]",
                cost: None,
                flags: (true, false, false),
            },
            RouteCase {
                route: MetricsRoute::EmergencyLocal,
                source: BadgeSource::Emergency,
                model: Some("local-vaultqa"),
                hosted: HostedBadge::opus(),
                badge: "[local · emergency · local-vaultqa]",
                cost: None,
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::EmergencyLocal,
                source: BadgeSource::DietQueued,
                model: Some("local-diet"),
                hosted: HostedBadge::opus(),
                badge: "[local · diet · local-diet + verify queued]",
                cost: None,
                flags: (false, true, false),
            },
        ];
        for c in cases {
            let (hv, vq, cu) = c.flags;
            let p = reply_provenance(
                &ok("Body."),
                &cfg,
                c.route,
                c.source,
                c.model.map(String::from),
                &c.hosted,
                cu,
            )
            .expect("provenance present for a non-empty reply with badges on");
            assert_eq!(p.route, c.route);
            assert_eq!(
                p.model.as_deref(),
                c.model,
                "backend model carried structurally"
            );
            assert_eq!(p.cost_usd, c.cost, "cost rides the hosted route only");
            assert_eq!(p.badge, c.badge, "badge byte-identical to the text badge");
            // The badge string embedded in provenance is exactly what finalize appends.
            let finalized = finalize_reply_badge(ok("Body."), &cfg, c.source, &c.hosted).unwrap();
            assert_eq!(
                finalized.0,
                format!("Body.\n\n{}", p.badge),
                "provenance.badge == appended badge"
            );
            assert_eq!(
                (
                    p.flags.hosted_verify,
                    p.flags.verify_queued,
                    p.flags.citations_unverified
                ),
                (hv, vq, cu)
            );
        }
    }

    #[test]
    fn emergency_citations_unverified_flag_flows_when_advisory_validator_failed() {
        let cfg = cfg_on();
        let p = reply_provenance(
            &ok("Best guess."),
            &cfg,
            MetricsRoute::EmergencyLocal,
            BadgeSource::Emergency,
            Some("local-vaultqa".into()),
            &HostedBadge::opus(),
            /* citations_unverified */ true,
        )
        .unwrap();
        assert!(
            p.flags.citations_unverified,
            "the advisory-fail emergency turn marks citations unverified"
        );
        assert_eq!(
            p.badge, "[local · emergency · local-vaultqa]",
            "badge string is unchanged by the flag"
        );
    }

    #[test]
    fn provenance_absent_when_badge_off_empty_or_error() {
        // Off → no provenance (mirrors: no badge appended).
        let mut off = cfg_on();
        off.model_badge = false;
        assert!(reply_provenance(
            &ok("Body."),
            &off,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            &HostedBadge::opus(),
            false
        )
        .is_none());

        let cfg = cfg_on();
        // Empty (directive-only) reply → no badge, so no provenance.
        assert!(reply_provenance(
            &ok(""),
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            &HostedBadge::opus(),
            false
        )
        .is_none());
        assert!(reply_provenance(
            &ok("   \n  "),
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            &HostedBadge::opus(),
            false
        )
        .is_none());
        // Error outcome → no badge, so no provenance.
        let err: Result<(String, Option<String>, Option<Directives>), ApiError> =
            Err((StatusCode::BAD_GATEWAY, "boom".into()));
        assert!(reply_provenance(
            &err,
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            &HostedBadge::opus(),
            false
        )
        .is_none());
    }

    #[test]
    fn shared_fixture_pins_every_badge_route_and_the_warning() {
        // The SHARED contract file both this test and the iOS app test read. It pins
        // the exact badge strings, the citations-unverified warning, and the assembled
        // reply text per route — so the bridge (producer) and the app (stripper) can
        // never drift. If this fails, the bridge changed a string the app relies on.
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/provenance.json"
        );
        let raw = std::fs::read_to_string(path).expect("shared provenance fixture is readable");
        let fx: Value = serde_json::from_str(&raw).expect("fixture is valid JSON");

        // 1. The warning constant IS the string the app strips.
        assert_eq!(
            CITATIONS_UNVERIFIED_WARNING,
            fx["citations_unverified_warning"].as_str().unwrap(),
            "emergency warning constant matches the shared fixture"
        );

        // A cfg whose local backends carry the fixture's model name.
        let mut cfg = cfg_on();
        cfg.vaultqa_backend = Some(("http://u".into(), "tok".into(), "local-oss".into()));
        cfg.diet_backend = Some(("http://u".into(), "tok".into(), "local-oss".into()));

        for case in fx["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let (source, cu) = match name {
                "hosted" | "hosted-glm-readonly" | "hosted-glm-write" => {
                    (BadgeSource::Hosted, false)
                }
                "vault-local" => (BadgeSource::Vault, false),
                "diet-local-hosted-verify" => (BadgeSource::DietVerify, false),
                "diet-local-verify-queued" => (BadgeSource::DietQueued, false),
                "emergency-local-verified" => (BadgeSource::Emergency, false),
                "emergency-local-citations-unverified" => (BadgeSource::Emergency, true),
                other => panic!("unmapped fixture case: {other}"),
            };
            let model = case["provenance"]["model"].as_str().map(String::from);
            // A hosted case names the ACTIVE model + cost + write marker; a local case's
            // hosted-badge argument is ignored (the badge derives from cfg).
            let hosted = if source == BadgeSource::Hosted {
                HostedBadge {
                    model_id: model.clone().unwrap_or_default(),
                    write_marked: case["hosted_write"].as_bool().unwrap_or(false),
                    cost_usd: case["provenance"]["cost_usd"].as_f64(),
                }
            } else {
                HostedBadge::opus()
            };
            let route: MetricsRoute =
                serde_json::from_value(case["provenance"]["route"].clone()).unwrap();
            let body = case["reply_body"].as_str().unwrap();

            // 2. The bridge PRODUCES exactly the fixture's provenance object.
            let p = reply_provenance(&ok(body), &cfg, route, source, model, &hosted, cu)
                .expect("provenance present for a fixture reply");
            assert_eq!(
                provenance_to_value(Some(&p)),
                case["provenance"],
                "provenance for `{name}` matches the fixture"
            );

            // 3. The bridge DELIVERS exactly the fixture's reply_text: body, then the
            //    emergency warning above the badge (only when unverified), then the badge.
            let base = if cu {
                format!("{CITATIONS_UNVERIFIED_WARNING}\n\n{body}")
            } else {
                body.to_string()
            };
            let delivered = append_badge(&base, &p.badge);
            assert_eq!(
                delivered,
                case["reply_text"].as_str().unwrap(),
                "assembled reply text for `{name}` matches the fixture"
            );
        }
    }

    #[test]
    fn provenance_serializes_to_the_pinned_wire_shape() {
        let cfg = cfg_on();
        let p = reply_provenance(
            &ok("Body."),
            &cfg,
            MetricsRoute::EmergencyLocal,
            BadgeSource::Emergency,
            Some("local-vaultqa".into()),
            &HostedBadge::opus(),
            true,
        )
        .unwrap();
        let v = provenance_to_value(Some(&p));
        assert_eq!(
            v["route"], "emergency-local",
            "route serializes kebab, same vocab as metrics"
        );
        assert_eq!(v["model"], "local-vaultqa");
        assert_eq!(v["badge"], "[local · emergency · local-vaultqa]");
        assert_eq!(v["flags"]["hosted_verify"], false);
        assert_eq!(v["flags"]["verify_queued"], false);
        assert_eq!(v["flags"]["citations_unverified"], true);
        // A local route carries no cost figure (the field is skipped when None).
        assert!(v.get("cost_usd").is_none(), "local route omits cost_usd");
        // None → JSON null (absent-provenance path).
        assert_eq!(provenance_to_value(None), Value::Null);
        // A hosted turn names the ACTIVE model and carries its cost.
        let hosted = reply_provenance(
            &ok("Body."),
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            Some("glm-5.2".into()),
            &hb("glm-5.2", false, Some(0.0021)),
            false,
        )
        .unwrap();
        let hv = provenance_to_value(Some(&hosted));
        assert_eq!(hv["model"], "glm-5.2");
        assert_eq!(hv["cost_usd"], 0.0021);
        assert_eq!(hv["badge"], "[glm-5.2 · $0.0021]");
    }
}
