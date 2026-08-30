//! **The live smoke** — one real call against one real endpoint.
//!
//! GATED OFF IN CI BY CONSTRUCTION: this is an `example`, not a test, so `cargo test`
//! never runs it. CI compiles it (`--all-targets`) and stops there, which is the property
//! wanted — the code stays honest without a network call ever being part of the gate.
//!
//! It exists because the conformance suite proves the adapters against a mock that this
//! repository wrote, and a mock agrees with whatever the code believes. Only a live
//! endpoint can disagree.
//!
//! ---- RUNNING IT ------------------------------------------------------------
//!
//! ```text
//!   JESSE_AGENT_WIRE=chat \
//!   JESSE_AGENT_BASE_URL=https://…/v1 \
//!   JESSE_AGENT_MODEL=… \
//!   JESSE_AGENT_TOKEN_ENV=SOME_PROVIDER_API_KEY \
//!   cargo run -p jesse-agent --example smoke
//! ```
//!
//! THE TOKEN IS NAMED, NOT PASSED. `JESSE_AGENT_TOKEN_ENV` holds the NAME of the variable
//! the key lives in; the key itself is never a value this program was handed on a command
//! line. That indirection is the difference between a credential that appears in shell
//! history and `ps` output and one that does not, and it costs one line of resolution.
//!
//! Nothing here prints the token, the base URL, or the response body. The URL is withheld
//! along with the token deliberately: a base URL frequently embeds a tenant or gateway
//! identifier, and this output is meant to be pasteable into a report.

use std::time::Instant;

use jesse_agent::provider::{
    build_provider, AuthScheme, Event, Message, ProviderConfig, Request, Sampling, ToolSpec, Wire,
};
use tokio_util::sync::CancellationToken;

fn env(name: &str) -> Result<String, String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("{name} is unset or empty"))
}

fn parse_wire(s: &str) -> Result<Wire, String> {
    match s.to_ascii_lowercase().as_str() {
        "messages" | "anthropic" => Ok(Wire::Messages),
        "chat" | "openai" | "openai_chat" => Ok(Wire::Chat),
        "responses" => Ok(Wire::Responses),
        other => Err(format!(
            "JESSE_AGENT_WIRE={other:?} is not one of: messages, chat, responses"
        )),
    }
}

#[tokio::main]
async fn main() -> Result<(), String> {
    // The caller resolves the environment; the crate never does (see `provider::config`).
    let wire = parse_wire(&env("JESSE_AGENT_WIRE")?)?;
    let base_url = env("JESSE_AGENT_BASE_URL")?;
    let model = env("JESSE_AGENT_MODEL")?;
    let token_env = env("JESSE_AGENT_TOKEN_ENV")?;
    let token = env(&token_env)
        .map_err(|_| format!("JESSE_AGENT_TOKEN_ENV names {token_env}, which is unset or empty"))?;

    let auth = AuthScheme::default_for(&base_url, token);
    let mut cfg = ProviderConfig::new(wire, &base_url, &model, auth);
    // Announced so the run is self-describing: which host defaults were picked matters
    // when reading the result, and none of these values is a secret.
    println!("wire            {wire}");
    println!("model           {model}");
    println!("token from      ${token_env}");
    println!(
        "quirks          reasoning_effort={} multiple_system={} strict_tools={}",
        cfg.quirks.reasoning_effort_supported,
        cfg.quirks.multiple_system_messages,
        cfg.quirks.strict_tools_supported
    );
    cfg.retries.max_attempts = 2;

    let provider = build_provider(cfg).map_err(|e| e.to_string())?;
    let caps = provider.capabilities();
    println!(
        "capabilities    tools={} streaming={} vision={} caching={} thinking={}",
        caps.tool_use, caps.streaming, caps.vision, caps.prompt_caching, caps.thinking
    );

    let req = Request {
        messages: vec![Message::user("What is 2+2? Use the `add` tool.")],
        tools: vec![ToolSpec {
            name: "add".into(),
            description: "Add two numbers and return the sum.".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "a": {"type": "number"},
                    "b": {"type": "number"}
                },
                "required": ["a", "b"]
            }),
            strict: false,
        }],
        sampling: Sampling {
            max_output_tokens: 256,
            ..Default::default()
        },
        request_tag: "smoke".into(),
        ..Default::default()
    };

    let started = Instant::now();
    let mut stream = provider
        .stream(&req, CancellationToken::new())
        .await
        .map_err(|e| format!("call failed before streaming: {e}"))?;

    println!("--- events ---");
    let mut text = String::new();
    let mut n = 0usize;
    while let Some(ev) = stream.recv().await {
        n += 1;
        match ev {
            // Deltas are COUNTED, not printed one per line: a real answer is hundreds of
            // them and the shape of the sequence is what this run is for.
            Event::TextDelta(t) => text.push_str(&t),
            Event::ThinkingDelta(_) => println!("{n:>3}  ThinkingDelta"),
            Event::ToolUseStart { id, name } => println!("{n:>3}  ToolUseStart {name} ({id})"),
            Event::ToolUseArgsDelta { json_fragment, .. } => {
                println!("{n:>3}  ToolUseArgsDelta {} bytes", json_fragment.len())
            }
            Event::ToolUseEnd { id } => println!("{n:>3}  ToolUseEnd ({id})"),
            Event::Usage(u) => println!(
                "{n:>3}  Usage in={:?} out={:?} cache_read={:?} cache_write={:?} req_id={:?}",
                u.input_tokens,
                u.output_tokens,
                u.cache_read_tokens,
                u.cache_write_tokens,
                u.provider_request_id
            ),
            Event::Done { stop_reason } => println!("{n:>3}  Done {stop_reason:?}"),
            Event::Error(e) => println!("{n:>3}  Error {e}"),
        }
    }
    if !text.is_empty() {
        println!("     (TextDelta total: {} chars)", text.chars().count());
    }

    println!("--- result ---");
    println!("wall            {} ms", started.elapsed().as_millis());
    match stream.audit().get() {
        Some(a) => println!("audit           {}", a.render()),
        None => println!("audit           (none recorded)"),
    }
    Ok(())
}
