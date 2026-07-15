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
//!   * `[hosted · <model>]`                       — a hosted turn with an explicit
//!     ambient `ANTHROPIC_MODEL`, else `[hosted]`.
//!
//! A fallback turn badges the backend that actually produced the DELIVERED text
//! (hosted), never the one that tried first. The switch is `JESSE_MODEL_BADGE`
//! (`on|off`, default on → `cfg.model_badge`).

use crate::*;

/// Which backend produced the delivered reply — the state the badge derives from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadgeSource {
    /// A hosted `run_claude_streaming` turn (including any diet/vault fallback).
    Hosted,
    /// A local diet entry that ran the blocking hosted verify.
    DietVerify,
    /// A local vault-QA answer.
    Vault,
}

/// Build the badge line for a delivered reply, or `None` when badges are off. Pure —
/// the model strings come from `cfg` (the configured local backends) and, for the
/// hosted case, from `hosted_model` (the ambient `ANTHROPIC_MODEL`, `None` → bare
/// `[hosted]`). Never reads model output.
pub fn model_badge_line(cfg: &Config, source: BadgeSource, hosted_model: Option<&str>) -> Option<String> {
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
        assert_eq!(out.matches("\n\n[hosted]").count(), 1, "one appended badge only");
    }

    #[test]
    fn finalize_applies_the_badge_for_each_source() {
        let cfg = cfg_on();
        for (source, expected) in [
            (BadgeSource::Hosted, "[hosted]"),
            (BadgeSource::Vault, "[local · vault · local-vaultqa]"),
            (BadgeSource::DietVerify, "[local · diet · local-diet + hosted verify]"),
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
        let out = finalize_reply_badge(
            Ok(("".into(), None, None)),
            &cfg,
            BadgeSource::Hosted,
            None,
        )
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
}
