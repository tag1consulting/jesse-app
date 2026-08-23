//! `jesse-sentinel` — the operator process. Wiring only: read the configuration, enforce
//! the two startup invariants, warn about everything that is merely degraded, then serve the
//! verb table and start the watchdog. All the logic lives in `jesse_bridge::sentinel`.
//!
//! It is a SECOND binary rather than a route on the bridge for one reason: the thing most
//! worth being able to restart is the bridge, and a restart verb that dies with the process
//! it restarts is not a restart verb. It shares the bridge's crate so that the bearer check,
//! the bind rules, the rate limiter and the APNs client are the same code, not a second
//! implementation of each that can drift.

use std::net::SocketAddr;

use jesse_bridge::sentinel::{
    sentinel_app, spawn_watchdog, Bins, Sentinel, SentinelConfig, SERVICE_SLOTS,
};
use jesse_bridge::{build_apns, env_truthy, is_bind_allowed};

#[tokio::main]
async fn main() {
    let cfg = match SentinelConfig::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("jesse-sentinel: refusing to start — {e}");
            std::process::exit(1);
        }
    };

    // Same bind rule as the bridge, and for the same reason: this service can restart
    // launchd jobs, so putting it on an untrusted interface is worse than putting the bridge
    // there. Loopback or CGNAT/tailnet only, unless the operator says otherwise.
    let allow_public = env_truthy("JESSE_ALLOW_PUBLIC_BIND");
    if !is_bind_allowed(&cfg.bind, allow_public) {
        eprintln!(
            "jesse-sentinel: refusing to bind {}: not a loopback or tailnet/CGNAT \
             (100.64.0.0/10) address. Set JESSE_SENTINEL_BIND to a safe address, or \
             JESSE_ALLOW_PUBLIC_BIND=1 to override.",
            cfg.bind
        );
        std::process::exit(1);
    }

    // ---- Everything below is DEGRADED, never fatal --------------------------------
    //
    // An operator process that will not boot is the failure this service exists to prevent,
    // so a missing binary, an unnamed label or an absent bridge token each cost their own
    // verbs and nothing else. Every one of them is named on stderr, which is the launchd
    // log, and visible again on `GET /sentinel/status`.
    let (_, missing) = Bins::resolve();
    if !missing.is_empty() {
        eprintln!(
            "jesse-sentinel: WARNING — {} external command(s) could not be resolved on this \
             host: {}. The probes and verbs that need them report the absence by name. Pin a \
             path with JESSE_SENTINEL_<NAME>_BIN.",
            missing.len(),
            missing.join(", ")
        );
    }
    let placeholders = cfg.placeholder_labels();
    if !placeholders.is_empty() {
        eprintln!(
            "jesse-sentinel: WARNING — {} service(s) still carry the documented placeholder \
             launchd label, so their restart verb addresses nothing:",
            placeholders.len()
        );
        for (slot, label) in &placeholders {
            eprintln!("    {} = {label}  (set {})", slot.slug(), slot.label_env());
        }
    }
    if cfg.bridge_token.is_none() {
        eprintln!(
            "jesse-sentinel: WARNING — JESSE_TOKEN is not set, so the sentinel cannot \
             authenticate to the bridge. /sentinel/status will report only what an \
             unauthenticated probe sees, and the two proxy verbs will refuse."
        );
    }
    if cfg.bridge_plist.is_none() {
        eprintln!(
            "jesse-sentinel: WARNING — JESSE_SENTINEL_BRIDGE_PLIST is not set; \
             POST /sentinel/bridge/reload-env has no file to bootstrap from and will refuse. \
             It is the ONLY way a plist environment change takes effect."
        );
    }
    if cfg.child_path.is_none() {
        eprintln!(
            "jesse-sentinel: NOTE — JESSE_SENTINEL_CHILD_PATH is not set, so `qmd status` is \
             probed with this process's PATH rather than the bridge child's. Copy the bridge \
             plist's PATH there, or the probe can report healthy while every turn's search \
             is broken."
        );
    }
    if cfg.autocommit_log.is_none() {
        eprintln!(
            "jesse-sentinel: NOTE — no autocommit log found (set JESSE_SENTINEL_AUTOCOMMIT_LOG, \
             or make sure the job's plist has a StandardOutPath). The autocommit watchdog rule \
             is inert without it."
        );
    }

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    // The same APNs client the bridge builds, from the same JESSE_APNS_* variables, pushing
    // to the same registered device. `None` when push is not configured: every alert then
    // logs and sends nothing, which is exactly the bridge's contract.
    let apns = build_apns();
    if apns.is_none() {
        eprintln!(
            "jesse-sentinel: WARNING — push is not configured (JESSE_APNS_*). The watchdog \
             will still fix what it can, but nothing will reach the phone."
        );
    }

    println!(
        "jesse-sentinel v{} → http://{addr}",
        env!("CARGO_PKG_VERSION")
    );
    println!("  state    {}", cfg.state_dir.display());
    println!("  bridge   {}", cfg.bridge_url);
    println!("  vault    {}", cfg.vault_repo.display());
    for slot in SERVICE_SLOTS {
        println!("  service  {:<11} {}", slot.slug(), cfg.label(slot));
    }
    // The token is NEVER printed. It is the value that grants `launchctl kickstart` on this
    // host, and stdout here is a launchd log.

    let sen = Sentinel::new(cfg, apns);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("jesse-sentinel: could not bind {addr}: {e}");
            std::process::exit(1);
        }
    };
    // Started before the socket is served so a sentinel that comes up to find the bridge
    // already dead begins counting immediately.
    spawn_watchdog(sen.clone());
    let app = sentinel_app(sen).into_make_service_with_connect_info::<SocketAddr>();
    if let Err(e) = axum::serve(listener, app).await {
        eprintln!("jesse-sentinel: server error: {e}");
        std::process::exit(1);
    }
}
