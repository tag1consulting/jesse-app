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

/// Build the badge line for a delivered reply, or `None` when badges are off. Pure —
/// the model strings come from `cfg` (the configured local backends) and, for the
/// hosted case, from `hosted_model` (the ambient `ANTHROPIC_MODEL`, `None` → bare
/// `[hosted]`). Never reads model output.
pub fn model_badge_line(
    cfg: &Config,
    source: BadgeSource,
    hosted_model: Option<&str>,
) -> Option<String> {
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
        BadgeSource::Hosted => match hosted_model {
            Some(m) => format!("[hosted · {m}]"),
            None => "[hosted]".to_string(),
        },
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
    /// The backend model that produced the reply, when known. `None` (serialized `null`)
    /// on a bare `[hosted]` turn with no ambient `ANTHROPIC_MODEL`.
    pub model: Option<String>,
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
    hosted_model: Option<&str>,
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
    let badge = model_badge_line(cfg, source, hosted_model)?;
    Some(Provenance {
        route,
        model,
        badge,
        flags: ProvenanceFlags::from_source(source, citations_unverified),
    })
}

/// Serialize an optional [`Provenance`] to the wire value used by BOTH the poll result
/// JSON and the SSE `done` frame, so the two paths are byte-consistent (mirrors
/// [`directives_to_value`]). `None` → JSON `null` (the app treats null/absent identically
/// and falls back to showing the reply text verbatim).
pub fn provenance_to_value(provenance: &Option<Provenance>) -> Value {
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
    hosted_model: Option<&str>,
) -> Result<(String, Option<String>, Option<Directives>), ApiError> {
    let Some(badge) = model_badge_line(cfg, source, hosted_model) else {
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

    #[test]
    fn badge_off_yields_no_line() {
        let mut cfg = cfg_on();
        cfg.model_badge = false;
        assert_eq!(model_badge_line(&cfg, BadgeSource::Hosted, Some("m")), None);
        assert_eq!(model_badge_line(&cfg, BadgeSource::Vault, None), None);
    }

    #[test]
    fn emergency_and_queued_badge_strings() {
        // Piece 4: the emergency ASK answer badges the vault-QA (emergency) model; a
        // queued diet Tell badges the diet model with the `+ verify queued` suffix.
        let cfg = cfg_on();
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Emergency, None).unwrap(),
            "[local · emergency · local-vaultqa]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::DietQueued, None).unwrap(),
            "[local · diet · local-diet + verify queued]"
        );
    }

    #[test]
    fn badge_strings_per_source() {
        let cfg = cfg_on();
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Vault, None).unwrap(),
            "[local · vault · local-vaultqa]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::DietVerify, None).unwrap(),
            "[local · diet · local-diet + hosted verify]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, Some("claude-opus-4-8")).unwrap(),
            "[hosted · claude-opus-4-8]"
        );
        assert_eq!(
            model_badge_line(&cfg, BadgeSource::Hosted, None).unwrap(),
            "[hosted]",
            "no ambient ANTHROPIC_MODEL → bare [hosted]"
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
        for (source, expected) in [
            (BadgeSource::Hosted, "[hosted]"),
            (BadgeSource::Vault, "[local · vault · local-vaultqa]"),
            (
                BadgeSource::DietVerify,
                "[local · diet · local-diet + hosted verify]",
            ),
        ] {
            let out = finalize_reply_badge(
                Ok(("Reply body.".into(), Some("sess".into()), None)),
                &cfg,
                source,
                None,
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
            Some("m"),
        )
        .unwrap();
        assert_eq!(out.0, "body", "badge off → reply unchanged");

        // On, but an EMPTY reply (a directive-only turn) is left empty so the app's
        // retry logic still fires.
        let cfg = cfg_on();
        let out =
            finalize_reply_badge(Ok(("".into(), None, None)), &cfg, BadgeSource::Hosted, None)
                .unwrap();
        assert_eq!(out.0, "", "an empty reply must not be badged");

        // On, but an error outcome passes through unchanged.
        let err = finalize_reply_badge(
            Err((StatusCode::BAD_GATEWAY, "boom".into())),
            &cfg,
            BadgeSource::Hosted,
            None,
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
        hosted: Option<&'static str>,
        badge: &'static str,
        flags: (bool, bool, bool), // (hosted_verify, verify_queued, citations_unverified)
    }

    #[test]
    fn provenance_present_matches_the_badge_for_each_route() {
        let cfg = cfg_on();
        let cases = [
            RouteCase {
                route: MetricsRoute::Hosted,
                source: BadgeSource::Hosted,
                model: Some("claude-opus-4-8"),
                hosted: Some("claude-opus-4-8"),
                badge: "[hosted · claude-opus-4-8]",
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::VaultqaLocal,
                source: BadgeSource::Vault,
                model: Some("local-vaultqa"),
                hosted: None,
                badge: "[local · vault · local-vaultqa]",
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::DietLocal,
                source: BadgeSource::DietVerify,
                model: Some("local-diet"),
                hosted: None,
                badge: "[local · diet · local-diet + hosted verify]",
                flags: (true, false, false),
            },
            RouteCase {
                route: MetricsRoute::EmergencyLocal,
                source: BadgeSource::Emergency,
                model: Some("local-vaultqa"),
                hosted: None,
                badge: "[local · emergency · local-vaultqa]",
                flags: (false, false, false),
            },
            RouteCase {
                route: MetricsRoute::EmergencyLocal,
                source: BadgeSource::DietQueued,
                model: Some("local-diet"),
                hosted: None,
                badge: "[local · diet · local-diet + verify queued]",
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
                c.hosted,
                cu,
            )
            .expect("provenance present for a non-empty reply with badges on");
            assert_eq!(p.route, c.route);
            assert_eq!(
                p.model.as_deref(),
                c.model,
                "backend model carried structurally"
            );
            assert_eq!(p.badge, c.badge, "badge byte-identical to the text badge");
            // The badge string embedded in provenance is exactly what finalize appends.
            let finalized = finalize_reply_badge(ok("Body."), &cfg, c.source, c.hosted).unwrap();
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
            None,
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
            Some("m"),
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
            None,
            false
        )
        .is_none());
        assert!(reply_provenance(
            &ok("   \n  "),
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            None,
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
            None,
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
                "hosted" | "hosted-bare" => (BadgeSource::Hosted, false),
                "vault-local" => (BadgeSource::Vault, false),
                "diet-local-hosted-verify" => (BadgeSource::DietVerify, false),
                "diet-local-verify-queued" => (BadgeSource::DietQueued, false),
                "emergency-local-verified" => (BadgeSource::Emergency, false),
                "emergency-local-citations-unverified" => (BadgeSource::Emergency, true),
                other => panic!("unmapped fixture case: {other}"),
            };
            let model = case["provenance"]["model"].as_str().map(String::from);
            let hosted = if source == BadgeSource::Hosted {
                model.clone()
            } else {
                None
            };
            let route: MetricsRoute =
                serde_json::from_value(case["provenance"]["route"].clone()).unwrap();
            let body = case["reply_body"].as_str().unwrap();

            // 2. The bridge PRODUCES exactly the fixture's provenance object.
            let p = reply_provenance(&ok(body), &cfg, route, source, model, hosted.as_deref(), cu)
                .expect("provenance present for a fixture reply");
            assert_eq!(
                provenance_to_value(&Some(p.clone())),
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
            None,
            true,
        )
        .unwrap();
        let v = provenance_to_value(&Some(p));
        assert_eq!(
            v["route"], "emergency-local",
            "route serializes kebab, same vocab as metrics"
        );
        assert_eq!(v["model"], "local-vaultqa");
        assert_eq!(v["badge"], "[local · emergency · local-vaultqa]");
        assert_eq!(v["flags"]["hosted_verify"], false);
        assert_eq!(v["flags"]["verify_queued"], false);
        assert_eq!(v["flags"]["citations_unverified"], true);
        // None → JSON null (absent-provenance path).
        assert_eq!(provenance_to_value(&None), Value::Null);
        // A bare hosted turn carries model: null but still a badge.
        let bare = reply_provenance(
            &ok("Body."),
            &cfg,
            MetricsRoute::Hosted,
            BadgeSource::Hosted,
            None,
            None,
            false,
        )
        .unwrap();
        let bv = provenance_to_value(&Some(bare));
        assert_eq!(bv["model"], Value::Null);
        assert_eq!(bv["badge"], "[hosted]");
    }
}
