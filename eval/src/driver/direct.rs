//! **The `direct` driver** — `jesse_agent::run_turn`, in this process.
//!
//! No child, no CLI, no stream-json on a pipe: the harness builds a provider, a vault tool
//! set over the task's workspace and a system prefix, calls the loop, and renders what came
//! back into the same transcript model the CLI driver produces. That last step is what makes
//! the two comparable — see [`super`].
//!
//! ---- THE TOKEN IS NAMED, NEVER PASSED ---------------------------------------
//!
//! `--token-env` holds the NAME of the environment variable the key lives in, exactly as
//! `jesse-agent turn` does it. A key passed as a flag is a key in shell history and in `ps`
//! output, and an eval run is the kind of thing people paste into a report.
//!
//! ---- THE TWO MOCKS ARE DIFFERENT ON PURPOSE ---------------------------------
//!
//! The CLI driver's `--mock` fakes a child's stdout AND fakes its side effects: a `files`
//! map is written into the workspace to stand in for what tools would have done, because
//! nothing in that path can actually run a tool.
//!
//! This driver's `--mock` is a SCRIPTED PROVIDER fixture
//! ([`jesse_agent::provider::scripted::ScriptFixture`]) — a list of model responses per task
//! id, each either text or tool calls with arguments. The loop then dispatches those calls
//! against the REAL tool set, over the REAL fixture workspace, and the files that end up on
//! disk are the ones the tools actually wrote. So it needs no `files` map: a mock run here
//! exercises argument parsing, path containment, the compare-and-swap and the write path,
//! with zero network. What it does NOT exercise is a model deciding anything, which is the
//! honest limit of both mocks.
//!
//! **THE ONE AFFORDANCE THE FIXTURE HAS BEYOND THE PROVIDER'S FORMAT** is
//! `{{hash:<vault path>}}`, substituted into string arguments against the live workspace
//! immediately before the turn. `vault_edit` requires the `expected_hash` from a prior read
//! and a fixture cannot know it, because it is the sha256 of a file the fixture itself is
//! about to change. Hard-coding the digest would work and would make every fixture a
//! rewrite away from a compare-and-swap failure that says nothing about the suite. The
//! substitution is documented in `eval/README.md` and applies to nothing else.

use super::{BoxFuture, Driver, PreparedWorkspace, TaskRun};
use crate::mapping::map_allowed_tools;
use crate::suite::Task;
use crate::transcript::Usage;
use jesse_agent::index::GrepIndex;
use jesse_agent::provider::scripted::{ScriptFixture, ScriptedProvider};
use jesse_agent::store::NoGuard;
use jesse_agent::tools::vault::{vault_tool_set, FetchConfig, VaultContext};
use jesse_agent::turn::{EventSink, StopReason, ToolActivity, TurnDeps, TurnInput};
use jesse_agent::{
    build_provider, render_persona, AuthScheme, Budget, FsVaultStore, Level, MemoryThreadStore,
    MemoryUsageSink, PersonaPack, PriceDeck, Provider, ProviderConfig, Scope, StaticToolSet,
    SystemBlock, SystemClock, Thinking, Tool, ToolSet, ToolSpec, TurnStopReason, Wire,
};
use std::collections::BTreeSet;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

/// The scope every eval turn runs under. Fixed, and spelled out rather than implied.
fn eval_scope() -> Scope {
    Scope::new("eval", "owner", "default")
}

/// Runs each task through the in-process agent loop.
pub struct DirectDriver {
    /// The endpoint's base URL. Required unless `--mock` is in play.
    pub base_url: Option<String>,
    pub wire: Wire,
    pub model: Option<String>,
    /// The NAME of the environment variable the API key lives in.
    pub token_env: Option<String>,
    /// A scripted-provider fixture, as raw JSON so `{{hash:…}}` can be resolved per task
    /// against a workspace that does not exist until the task is prepared.
    pub mock: Option<serde_json::Value>,
    pub timeout: Duration,
    pub prices: PriceDeck,
    /// The persona every task inherits when it names none.
    pub persona: PersonaPack,
    pub thinking: Thinking,
}

impl Driver for DirectDriver {
    fn id(&self) -> &'static str {
        "direct"
    }

    fn endpoint(&self) -> Option<String> {
        self.base_url.clone()
    }

    fn wire(&self) -> Option<String> {
        Some(format!("{:?}", self.wire).to_lowercase())
    }

    fn model(&self) -> Option<String> {
        self.model.clone()
    }

    fn is_mock(&self) -> bool {
        self.mock.is_some()
    }

    fn run_task<'a>(
        &'a self,
        task: &'a Task,
        workspace: &'a PreparedWorkspace,
        cancel: CancellationToken,
    ) -> BoxFuture<'a, TaskRun> {
        Box::pin(async move {
            match self.run_one(task, workspace, cancel).await {
                Ok(run) => run,
                Err(e) => TaskRun::failed(e),
            }
        })
    }
}

impl DirectDriver {
    async fn run_one(
        &self,
        task: &Task,
        workspace: &PreparedWorkspace,
        cancel: CancellationToken,
    ) -> Result<TaskRun, String> {
        let level = task.level();
        // THE SECOND LOCK ON THE VAULT. `Task::validate` already refuses `vault-readonly`
        // at `write` when the suite loads; this refuses it again at the point the tool set
        // would actually be built, because that is the line a future caller could reach
        // without going through a suite file at all.
        if workspace.kind == crate::suite::Workspace::VaultReadonly && level > Level::Read {
            return Err(format!(
                "task '{}' would build a {level} tool set over the real vault",
                task.id
            ));
        }
        let granted = map_allowed_tools(&task.allowed_tools)
            .map_err(|e| format!("task '{}': {e}", task.id))?;

        // ---- The vault ---------------------------------------------------
        let store = Arc::new(
            FsVaultStore::open(&workspace.dir)
                .map_err(|e| format!("could not open {}: {e}", workspace.dir.display()))?,
        );
        let index = Arc::new(GrepIndex::new(store.clone()));
        let vault = Arc::new(VaultContext {
            store,
            index,
            // The workspace is a fresh temp dir nobody else is touching (or, for
            // `vault-readonly`, a directory this turn cannot write to at all), which is
            // exactly the case the no-op guard documents itself as correct for.
            guard: Arc::new(NoGuard),
        });
        // AN EMPTY FETCH ALLOWLIST, always. No suite may grant egress — `fetch_url` is
        // reachable from no row of the mapping table — and this is the second lock on the
        // same door: even a tool set built with the tool present refuses every URL.
        let tools = vault_tool_set(vault, FetchConfig::default(), level)?;
        let tools = GrantedToolSet::new(tools, granted);

        // ---- The system prefix -------------------------------------------
        let pack = task.persona.clone().unwrap_or_else(|| self.persona.clone());
        let mut system = render_persona(&pack, self.wire);
        system.extend(task.system.iter().map(|s| SystemBlock::plain(s.clone())));

        // ---- The provider -------------------------------------------------
        let provider: Box<dyn Provider> = match &self.mock {
            Some(raw) => Box::new(self.scripted_provider(task, &workspace.dir, raw)?),
            None => {
                let base_url = self
                    .base_url
                    .as_deref()
                    .ok_or("the direct driver needs --endpoint (or --mock)")?;
                let model = self
                    .model
                    .as_deref()
                    .ok_or("the direct driver needs --model (or --mock)")?;
                let auth = match &self.token_env {
                    Some(name) => {
                        let token = std::env::var(name)
                            .ok()
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                            .ok_or_else(|| {
                                format!("--token-env names {name}, which is unset or empty")
                            })?;
                        AuthScheme::default_for(base_url, token)
                    }
                    None => AuthScheme::None,
                };
                build_provider(ProviderConfig::new(self.wire, base_url, model, auth))
                    .map_err(|e| e.to_string())?
            }
        };

        // ---- The turn ------------------------------------------------------
        let threads = MemoryThreadStore::new();
        let usage_sink = MemoryUsageSink::new();
        let sink = TimingSink::default();
        let manifest: Vec<String> = tools
            .manifest()
            .iter()
            .map(|t: &ToolSpec| t.name.clone())
            .collect();

        let input = TurnInput {
            scope: eval_scope(),
            turn_id: format!("eval-{}", task.id),
            thread_id: None,
            system,
            user_text: task.prompt.clone(),
            user_images: Vec::new(),
            budget: Budget::with_wall(self.timeout),
            prices: self.prices,
            thinking: self.thinking,
            tools: Arc::new(tools),
            // NO ARTIFACT CHANNEL. `deliver_artifact` is reachable from no row of the
            // mapping table either, and with no directory it refuses rather than choosing
            // one — the same posture the CLI has, where nothing sweeps a stray file.
            artifact_dir: None,
        };
        let deps = TurnDeps {
            provider: provider.as_ref(),
            threads: &threads,
            usage: &usage_sink,
            clock: Arc::new(SystemClock::new()),
        };

        let start = Instant::now();
        let outcome = jesse_agent::run_turn(input, &deps, &sink, cancel).await;
        let wall_ms = start.elapsed().as_millis() as u64;

        // ---- The transcript ------------------------------------------------
        let harness_error = match &outcome.stop_reason {
            TurnStopReason::Provider(e) => Some(format!("provider call failed: {e}")),
            TurnStopReason::Store(m) => Some(format!("thread store failed: {m}")),
            TurnStopReason::Other(m) => Some(format!("turn failed: {m}")),
            _ => None,
        };
        let finished = matches!(
            outcome.stop_reason,
            StopReason::EndTurn | StopReason::MaxTokens | StopReason::StopSequence
        );

        let mut lines = vec![serde_json::json!({
            "type": "system",
            "subtype": "init",
            "driver": "direct",
            "wire": format!("{:?}", self.wire).to_lowercase(),
            "level": format!("{level}"),
            "manifest": manifest,
        })
        .to_string()];
        for t in &outcome.trace.tools {
            // One assistant message per tool call, in dispatch order — the shape
            // `transcript::parse` counts and names. The outcome (`ok` / `refused` /
            // `failed`) rides alongside as a field the parser ignores and a human reading
            // the persisted file does not have to guess at.
            lines.push(
                serde_json::json!({
                    "type": "assistant",
                    "message": {"content": [{
                        "type": "tool_use",
                        "name": t.name,
                        "class": format!("{}", t.class),
                        "ms": t.ms,
                        "outcome": format!("{}", t.outcome),
                    }]}
                })
                .to_string(),
            );
        }
        if !outcome.text.is_empty() {
            lines.push(
                serde_json::json!({
                    "type": "stream_event",
                    "event": {"type": "content_block_delta",
                              "delta": {"type": "text_delta", "text": outcome.text}}
                })
                .to_string(),
            );
        }
        // The terminal line, UNLESS the turn failed at the harness level. A provider that
        // could not be reached did not produce a turn that ended, and saying it did would
        // let `completed` pass for a run that never happened.
        if harness_error.is_none() {
            lines.push(
                serde_json::json!({
                    "type": "result",
                    "subtype": if finished { "success" } else { "stopped" },
                    "is_error": !finished,
                    "stop_reason": outcome.stop_reason.label(),
                    "result": outcome.text,
                    "iterations": outcome.iterations,
                    "cost_usd": outcome.cost_usd,
                    "usage": {
                        "input_tokens": outcome.usage.input_tokens.unwrap_or(0),
                        "output_tokens": outcome.usage.output_tokens.unwrap_or(0),
                        "cache_read_input_tokens": outcome.usage.cache_read_input_tokens.unwrap_or(0),
                        "cache_creation_input_tokens": outcome.usage.cache_creation_input_tokens.unwrap_or(0),
                    }
                })
                .to_string(),
            );
        }

        let mut run = TaskRun::from_lines(lines, wall_ms, sink.ttft_ms());
        run.error = harness_error;
        // The loop's own aggregate, not a re-derivation: the result line above carries the
        // same four numbers, and this is the one that came from the usage records.
        run.usage = Usage {
            input_tokens: outcome.usage.input_tokens.unwrap_or(0),
            output_tokens: outcome.usage.output_tokens.unwrap_or(0),
            cache_read_input_tokens: outcome.usage.cache_read_input_tokens.unwrap_or(0),
            cache_creation_input_tokens: outcome.usage.cache_creation_input_tokens.unwrap_or(0),
        };
        Ok(run)
    }

    /// Build the scripted provider for one task from the fixture.
    fn scripted_provider(
        &self,
        task: &Task,
        dir: &Path,
        raw: &serde_json::Value,
    ) -> Result<ScriptedProvider, String> {
        let mut resolved = raw.clone();
        substitute(&mut resolved, dir);
        let fixture = ScriptFixture::from_json(
            serde_json::to_vec(&resolved)
                .map_err(|e| e.to_string())?
                .as_slice(),
        )?;
        let steps = fixture
            .steps_for(&task.id)
            .ok_or_else(|| format!("no scripted response for task '{}'", task.id))?;
        Ok(ScriptedProvider::new(
            self.wire,
            self.model.clone().unwrap_or_else(|| "scripted".to_string()),
            steps,
        ))
    }
}

/// Replace `{{hash:<path>}}` in every string of a fixture with that workspace file's
/// current content hash. A path that does not exist is left as written, so the failure a
/// fixture author sees is a compare-and-swap refusal naming a hash that is obviously a
/// placeholder, rather than a silent empty string.
fn substitute(value: &mut serde_json::Value, dir: &Path) {
    match value {
        serde_json::Value::String(s) => {
            if let Some(rest) = s.strip_prefix("{{hash:") {
                if let Some(path) = rest.strip_suffix("}}") {
                    if let Ok(bytes) = std::fs::read(dir.join(path)) {
                        *s = jesse_agent::ContentHash::of(&bytes).as_str().to_string();
                    }
                }
            }
        }
        serde_json::Value::Array(a) => a.iter_mut().for_each(|v| substitute(v, dir)),
        serde_json::Value::Object(o) => o.values_mut().for_each(|v| substitute(v, dir)),
        _ => {}
    }
}

// ===========================================================================
// The granted subset
// ===========================================================================

/// A tool set narrowed to the names a task's allowlist granted.
///
/// The level already decided what MAY be exposed; this decides what this TASK gets, which
/// is the direct-driver reading of `allowed_tools`. Both halves are enforced the same way —
/// a withheld tool is absent from the manifest AND unreachable from `get`, so a model that
/// names it anyway gets a dispatch failure rather than the tool.
struct GrantedToolSet {
    inner: StaticToolSet,
    granted: BTreeSet<String>,
}

impl GrantedToolSet {
    fn new(inner: StaticToolSet, granted: BTreeSet<String>) -> Self {
        GrantedToolSet { inner, granted }
    }
}

impl ToolSet for GrantedToolSet {
    fn manifest(&self) -> Vec<ToolSpec> {
        self.inner
            .manifest()
            .into_iter()
            .filter(|t| self.granted.contains(&t.name))
            .collect()
    }

    fn get(&self, name: &str) -> Option<&dyn Tool> {
        if !self.granted.contains(name) {
            return None;
        }
        self.inner.get(name)
    }

    fn max_level(&self) -> Level {
        self.inner.max_level()
    }
}

// ===========================================================================
// The sink
// ===========================================================================

/// Records when the first visible text arrived, and drops everything else.
///
/// Time to first text is the one thing the loop does not report and the harness has always
/// measured for itself — on the CLI path by timestamping stdout lines, here by timestamping
/// the first delta. Same number, same meaning, both drivers.
struct TimingSink {
    start: Instant,
    first_text: Mutex<Option<u64>>,
}

impl Default for TimingSink {
    fn default() -> Self {
        TimingSink {
            start: Instant::now(),
            first_text: Mutex::new(None),
        }
    }
}

impl TimingSink {
    fn ttft_ms(&self) -> Option<u64> {
        *self.first_text.lock().expect("ttft poisoned")
    }
}

impl EventSink for TimingSink {
    fn on_text_delta(&self, delta: &str) {
        if delta.is_empty() {
            return;
        }
        let mut g = self.first_text.lock().expect("ttft poisoned");
        if g.is_none() {
            *g = Some(self.start.elapsed().as_millis() as u64);
        }
    }

    fn on_tool_activity(&self, _activity: ToolActivity) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hash_placeholder_resolves_against_the_workspace() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("note.md"), "hello\n").unwrap();
        let mut v = serde_json::json!({
            "calls": [{"arguments": {"expected_hash": "{{hash:note.md}}", "id": "note.md"}}]
        });
        substitute(&mut v, dir.path());
        let got = v["calls"][0]["arguments"]["expected_hash"]
            .as_str()
            .unwrap();
        assert_eq!(got, jesse_agent::ContentHash::of(b"hello\n").as_str());
        // Untouched strings stay untouched.
        assert_eq!(v["calls"][0]["arguments"]["id"], "note.md");
    }

    #[test]
    fn a_placeholder_for_a_missing_file_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = serde_json::json!({"h": "{{hash:nope.md}}"});
        substitute(&mut v, dir.path());
        assert_eq!(v["h"], "{{hash:nope.md}}");
    }
}
