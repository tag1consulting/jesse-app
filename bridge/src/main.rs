//! Jesse Bridge binary — wiring only. All logic lives in the `jesse_bridge`
//! library crate (see `lib.rs` and its modules); `main` just reads the config,
//! enforces the startup invariants, prints the pairing QR, and serves the router.

use std::path::Path;

use jesse_bridge::{
    app, binary_exists, bind_broker, build_apns, detect_binary_drift, env_string, env_truthy,
    export_mcp_server_env, harness_bin_env, harness_default_bin, harnesses_in_use, is_bind_allowed,
    load_local_models, manual_pairing_lines, pairing_payload, qr_env_tristate, sentinel_advert,
    serve_broker, settings_permission_drift, show_qr_opt_in, show_token_opt_in,
    spawn_eviction_task, spawn_scheduler, spawn_session_gc_task, start_health_prober,
    validate_model_config, AppState, Config, ConfigError, QrArt, TokenVisibility, BINARY_DRIFT,
    CONTAINMENT_RECORDS, SETTINGS_DRIFT,
};

#[tokio::main]
async fn main() {
    // BEFORE any child spawns: republish the plist's `JESSE_*` credentials under the names
    // the MCP servers read, and supply their non-secret settings. Both harnesses depend on
    // this having already run — Claude Code because its subprocesses inherit this
    // environment, Codex because `env_vars` can only forward a variable that exists here.
    export_mcp_server_env();

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
    let mut errors = validate_model_config(&cfg, &declared, CONTAINMENT_RECORDS);
    // The `[concurrency]` table joins the SAME gate. A misspelled model id there is refused by
    // name rather than silently ignored — a config surface that quietly does nothing is the
    // failure mode this project keeps designing against.
    if let Err(slot_errors) = cfg.slot_plan() {
        errors.extend(slot_errors.into_iter().map(|message| ConfigError {
            model: None,
            message,
        }));
    }
    // The `[[schedule]]` table joins the same gate for the TWO problems that make an
    // operator's intent unknowable rather than merely wrong: two entries sharing an `id`
    // (which one is "nightly"?) and a cycle in the `after` graph (which link runs first?).
    // Every OTHER scheduler misconfiguration is deliberately not here — it disables that
    // one entry, logs it by name, and leaves the rest of the schedule running (see
    // `spawn_scheduler`), because a bad job must never take the service down.
    errors.extend(cfg.schedule.fatal.iter().map(|message| ConfigError {
        model: None,
        message: message.clone(),
    }));
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

    // The DEPRECATED single-limit key, announced rather than silently applied. An operator who
    // set it to 1 on purpose gets a global ceiling of 1, which is exactly the pre-0.60.0
    // behavior — but they are told, because the key they set no longer means what it did.
    if let Some(n) = cfg.concurrency.legacy_max_concurrency {
        eprintln!(
            "jesse-bridge: NOTE — JESSE_MAX_CONCURRENCY is deprecated. Its value ({n}) is being \
             used as the GLOBAL CEILING on turns in flight across all models. Per-model slots \
             now come from the [concurrency] table (or JESSE_MODEL_<ID>_CONCURRENCY); set \
             [concurrency].total or JESSE_MAX_TURNS to name the ceiling directly."
        );
    }

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
    //
    // The QR encodes the FULL bearer token, so it is TTY-gated: printed only when
    // stdout is a terminal (someone is there to scan it). When stdout is a pipe —
    // a container, launchd — stdout is the log stream, and every restart would
    // republish the token into whatever aggregation is attached. Force it back
    // with `--show-qr` or JESSE_SHOW_QR=1; pin it OFF with JESSE_SHOW_QR=0 (for a
    // PTY that is still log-collected — `docker run -t`, a pod's `tty: true`).
    let advertise_host =
        std::env::var("JESSE_ADVERTISE_HOST").unwrap_or_else(|_| state.cfg.bind.clone());
    // The SENTINEL's coordinates, when this deployment runs one (see `crate::sentinel`).
    // Read once, here, so the QR and the manual lines cannot disagree about whether there is
    // a second service to pair.
    let sentinel = sentinel_advert(&advertise_host);
    let args: Vec<String> = std::env::args().collect();
    let qr_env = qr_env_tristate(env_string("JESSE_SHOW_QR").as_deref());
    let show_qr = show_qr_opt_in(&args, qr_env, {
        use std::io::IsTerminal;
        std::io::stdout().is_terminal()
    });
    let mut qr = QrArt::Suppressed;
    if show_qr {
        let payload = pairing_payload(
            &advertise_host,
            state.cfg.port,
            &state.cfg.token,
            sentinel.as_ref(),
        );
        // Log-and-degrade like every other startup fallibility in this file
        // (build_apns, the broker bind): the QR is a convenience with its fallback
        // printed right below, and DataTooLong is reachable — JESSE_ADVERTISE_HOST
        // is operator-controlled and unbounded.
        match qrcode::QrCode::new(payload.as_bytes()) {
            Ok(code) => {
                let art = code
                    .render::<qrcode::render::unicode::Dense1x2>()
                    .quiet_zone(true)
                    .build();
                println!("{art}");
                qr = QrArt::Shown;
            }
            Err(e) => eprintln!(
                "jesse-bridge: WARNING — could not render the pairing QR ({e}); pair \
                 manually with the lines below. If JESSE_ADVERTISE_HOST is unusually \
                 long, shortening it may help."
            ),
        }
    } else if qr_env != Some(false) {
        // The gate's decision is auditable, and the recovery hint lives on STDERR —
        // never in the stdout pairing lines, which are exactly the log stream the
        // hint must not push the token into. Silent when the operator pinned the QR
        // off themselves: they already know.
        eprintln!(
            "jesse-bridge: pairing QR suppressed — stdout is not a terminal, so the QR \
             (which encodes the bearer token) would land in the log stream. Pass \
             --show-qr or set JESSE_SHOW_QR=1 to print it anyway; set JESSE_SHOW_QR=0 \
             to silence this note."
        );
    }
    // Print the manual-pairing fallback under the QR (or alone when the QR is
    // suppressed or failed to render). The plaintext token line is omitted by
    // default so the raw token stays out of scrollback / launchd logs; a shown QR
    // still encodes it. Opt in with `--show-token` or JESSE_SHOW_TOKEN=1.
    let show_token = show_token_opt_in(&args, env_truthy("JESSE_SHOW_TOKEN"));
    for line in manual_pairing_lines(
        &advertise_host,
        state.cfg.port,
        &state.cfg.token,
        if show_token {
            TokenVisibility::Shown
        } else {
            TokenVisibility::Hidden
        },
        qr,
        sentinel.as_ref(),
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
    // THE ARTIFACT STORE'S STARTUP PASS: one eviction before serving, then the usage
    // line. The line is here rather than only after an eviction because the number worth
    // watching is the one at boot — a store that has been growing for a month is visible
    // in the log the morning it matters, not the day it fills the disk.
    state.artifacts.evict();
    if state.artifacts.is_available() {
        let usage = state.artifacts.usage();
        eprintln!(
            "jesse-bridge: artifact store: {} file(s), {} MB (ttl {}d, high-water {} MB)",
            usage.files,
            usage.bytes / (1024 * 1024),
            state.cfg.artifact_ttl_days,
            state.cfg.artifact_store_max_bytes / (1024 * 1024),
        );
    }
    // Evict expired jobs on a periodic background task rather than on the request
    // hot path (H3), so a sweep's file unlinks never delay a turn.
    spawn_eviction_task(state.jobs.clone(), state.artifacts.clone());
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
    // THE VAULT WRITE LOCK'S BROKER. Children's `PreToolUse` / `PostToolUse` hooks connect to
    // this socket to take and release per-file locks; the bridge holds them, and releases
    // every lock a turn holds when that turn's task ends (see `TurnLockRelease`).
    //
    // Bound in the STATE DIR, which is reachable by BOTH harnesses' hooks — a Codex child's
    // own sandbox cannot write there, but its hook subprocess is not sandboxed and can. That
    // measurement is what let this ship without widening `sandbox_workspace_write`.
    //
    // A bind failure DISARMS the lock rather than blocking boot, and that degradation is safe
    // because the slot plan is resolved independently: a write-level model whose harness
    // cannot lock is already capped at one slot, and with no helper or no socket no turn is
    // handed a `WriteLockChild` at all. The result is a bridge that behaves like 0.59.0.
    match (state.cfg.writelock_socket(), state.hook_helper.clone()) {
        (Some(path), Some(helper)) => match bind_broker(&path) {
            Ok(listener) => {
                println!(
                    "jesse-bridge: vault write lock armed — broker {} , helper {}",
                    path.display(),
                    helper.display()
                );
                tokio::spawn(serve_broker(listener, state.broker.clone()));
            }
            Err(e) => eprintln!(
                "jesse-bridge: WARNING — could not bind the write-lock broker at {} ({e}). \
                 Concurrent write-level turns are DISARMED; the bridge will serve them one at \
                 a time.",
                path.display()
            ),
        },
        (_, None) => eprintln!(
            "jesse-bridge: WARNING — the `jesse-hook` helper was not found beside this binary. \
             The vault write lock is DISARMED; write-level turns will not run concurrently."
        ),
        (None, _) => eprintln!(
            "jesse-bridge: WARNING — no state dir, so there is nowhere to put the write-lock \
             broker socket. The vault write lock is DISARMED."
        ),
    }
    // THE SCHEDULER'S TICK. Started last, once every other subsystem the turn path needs
    // is up, because a scheduled turn runs through exactly the same path a phone request
    // takes. A deploy with no `[[schedule]]` entries starts no task at all; entries that
    // failed validation are logged here, by name, and their neighbours still run.
    spawn_scheduler(state.clone());
    axum::serve(listener, app(state))
        .await
        .expect("server error");
}
