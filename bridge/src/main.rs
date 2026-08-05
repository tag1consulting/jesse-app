//! Jesse Bridge binary — wiring only. All logic lives in the `jesse_bridge`
//! library crate (see `lib.rs` and its modules); `main` just reads the config,
//! enforces the startup invariants, prints the pairing QR, and serves the router.

use std::path::Path;

use jesse_bridge::{
    app, binary_exists, build_apns, detect_binary_drift, env_string, env_truthy, harness_bin_env,
    settings_permission_drift, SETTINGS_DRIFT,
    harness_default_bin, harnesses_in_use, is_bind_allowed, load_local_models,
    manual_pairing_lines, pairing_payload, show_token_opt_in, spawn_eviction_task,
    spawn_session_gc_task, start_health_prober, validate_model_config, AppState, Config,
    BINARY_DRIFT, CONTAINMENT_RECORDS,
};

#[tokio::main]
async fn main() {
    let cfg = Config::from_env();

    if cfg.token.is_empty() {
        eprintln!("JESSE_TOKEN is not set — refusing to start.");
        std::process::exit(1);
    }
    if !Path::new(&cfg.vault).is_dir() {
        eprintln!("Vault not found: {} — set JESSE_VAULT.", cfg.vault);
        std::process::exit(1);
    }
    if !binary_exists(&cfg.claude_bin) {
        eprintln!(
            "claude binary not found: {} — set JESSE_CLAUDE_BIN.",
            cfg.claude_bin
        );
        std::process::exit(1);
    }
    // THE STARTUP GATE: config cannot grant what containment has not proven.
    //
    // Every rejection here is fatal and names the model it belongs to. It runs BEFORE the
    // socket opens and before any child can be spawned, because the failure it prevents is
    // a bridge that serves turns at a posture the committed containment record never
    // probed. A silently-ignored key would be a silent security downgrade, so nothing here
    // warns and continues. See `levelgate`.
    let declared = load_local_models(&cfg.home);
    let errors = validate_model_config(&cfg, &declared, CONTAINMENT_RECORDS);
    if !errors.is_empty() {
        eprintln!(
            "jesse-bridge: refusing to start — {} configuration problem(s):",
            errors.len()
        );
        for e in &errors {
            eprintln!("  - {e}");
        }
        std::process::exit(1);
    }
    // ADVISORY, never fatal: is each harness's live agent binary the one its record was taken
    // with? A self-updating CLI must not be able to block boot (see `detect_binary_drift`),
    // but a record silently describing a binary nobody is running is exactly the quiet
    // staleness this project cannot afford. So: warn loudly, serve anyway, and report it on
    // `/health` so it is visible without reading logs.
    let drift = detect_binary_drift(&cfg, CONTAINMENT_RECORDS);
    for d in &drift {
        eprintln!(
            "jesse-bridge: WARNING — containment record for harness '{}' was taken against \
             {}, but the installed binary is {}. The record still gates startup, but it now \
             describes a binary that is not running. Re-run the containment battery and \
             commit the record: cargo run --features=containment-probe --bin \
             containment-probe -- --write --harness {}",
            d.harness, d.recorded, d.live, d.harness
        );
    }
    let _ = BINARY_DRIFT.set(drift);

    // The one settings scope the child still loads. `local` is excluded by
    // `--setting-sources user,project`; `project` is kept for the vault's hooks, so a
    // permission entry appearing THERE is the remaining way to grant a tool the record
    // cannot see. Advisory and loud — never silent. See `settings_permission_drift`.
    let settings_grants = settings_permission_drift(&cfg);
    if !settings_grants.is_empty() {
        eprintln!(
            "jesse-bridge: WARNING — {} permission entr(ies) in {}/.claude/settings.json are \
             granted to every turn but are NOT in the containment record and NOT checked by \
             the startup gate. Move them to DEFAULT_ALLOWED_TOOLS (and re-run the battery), \
             or delete them:",
            settings_grants.len(),
            cfg.vault
        );
        for g in &settings_grants {
            eprintln!("    {g}");
        }
    }
    let _ = SETTINGS_DRIFT.set(settings_grants);

    // One binary check per harness some configured model actually references. A config full
    // of Codex models must not demand a Claude binary for the models it does not have — and
    // the ambient default keeps `claude-code` in the list regardless.
    for id in harnesses_in_use(&cfg) {
        let bin = harness_bin_env(&id)
            .and_then(env_string)
            .or_else(|| harness_default_bin(&id).map(str::to_string));
        match bin {
            Some(bin) if binary_exists(&bin) => {}
            Some(bin) => {
                eprintln!(
                    "jesse-bridge: harness '{id}' binary not found: {bin} — set {}.",
                    harness_bin_env(&id).unwrap_or("its binary path variable")
                );
                std::process::exit(1);
            }
            None => {
                eprintln!("jesse-bridge: harness '{id}' has no known binary path.");
                std::process::exit(1);
            }
        }
    }

    // If a custom attachment scratch base is set, it must already exist — fail
    // fast rather than surfacing a write error on the first attachment turn.
    if let Some(dir) = &cfg.scratch_dir {
        if !Path::new(dir).is_dir() {
            eprintln!("JESSE_SCRATCH_DIR is not a directory: {dir}");
            std::process::exit(1);
        }
    }

    // Refuse an unsafe bind (C2) before opening a socket. Only loopback or
    // CGNAT/tailnet space is allowed unless JESSE_ALLOW_PUBLIC_BIND is set.
    let allow_public = env_truthy("JESSE_ALLOW_PUBLIC_BIND");
    if !is_bind_allowed(&cfg.bind, allow_public) {
        eprintln!(
            "Refusing to bind {}: not a loopback or tailnet/CGNAT (100.64.0.0/10) \
             address. This would expose the bridge on an untrusted network. Set \
             JESSE_BIND to a safe address, or JESSE_ALLOW_PUBLIC_BIND=1 to override.",
            cfg.bind
        );
        std::process::exit(1);
    }

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let mut state = AppState::new(cfg);
    // Install the APNs client if push is configured (JESSE_APNS_* set and the key
    // loads). `None` leaves every push path a no-op — the bridge behaves exactly
    // as it did before. `build_apns` logs whether push is enabled or why it isn't.
    state.apns = build_apns();

    // Pairing QR — scan it from the app's Settings to fill in host/port/token.
    // The advertised host defaults to the bound IP (reliably reachable on the
    // tailnet; the ts.net name can have DNS quirks). Override with
    // JESSE_ADVERTISE_HOST to force the MagicDNS name into the QR instead.
    let advertise_host =
        std::env::var("JESSE_ADVERTISE_HOST").unwrap_or_else(|_| state.cfg.bind.clone());
    let payload = pairing_payload(&advertise_host, state.cfg.port, &state.cfg.token);
    let code = qrcode::QrCode::new(payload.as_bytes()).expect("qr encode");
    let art = code
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .build();
    println!("{art}");
    // Print the manual-pairing fallback under the QR. The plaintext token line is
    // omitted by default so the raw token stays out of scrollback / launchd logs;
    // the QR still encodes it. Opt in with `--show-token` or JESSE_SHOW_TOKEN=1.
    let args: Vec<String> = std::env::args().collect();
    let show_token = show_token_opt_in(&args, env_truthy("JESSE_SHOW_TOKEN"));
    for line in manual_pairing_lines(
        &advertise_host,
        state.cfg.port,
        &state.cfg.token,
        show_token,
    ) {
        println!("{line}");
    }

    println!(
        "Jesse Bridge v{} → http://{addr}  (vault: {})",
        env!("CARGO_PKG_VERSION"),
        state.cfg.vault
    );
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    // Evict expired jobs on a periodic background task rather than on the request
    // hot path (H3), so a sweep's file unlinks never delay a turn.
    spawn_eviction_task(state.jobs.clone());
    // Reclaim orphaned vault-project Claude Code sessions older than
    // JESSE_SESSION_TTL_DAYS on a background sweep (one run at startup, then
    // periodic). Scoped to the vault project only; an actively-resumed session
    // touches its mtime and is never reclaimed.
    spawn_session_gc_task(
        state.cfg.clone(),
        state.conversations.clone(),
        state.titles.clone(),
        state.flags.clone(),
    );
    // Health-probe each CONFIGURED non-ambient model on its interval so the apps only offer
    // models that are reachable right now. A no-op for an opus-only deploy (no targets), so
    // the health path is entirely absent there. Never blocks a turn (detached tasks); a
    // probe failure only demotes that model to unhealthy, never disturbs the bridge.
    start_health_prober(state.health.clone(), &state.cfg.model_registry);
    axum::serve(listener, app(state))
        .await
        .expect("server error");
}
