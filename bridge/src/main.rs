//! Jesse Bridge binary — wiring only. All logic lives in the `jesse_bridge`
//! library crate (see `lib.rs` and its modules); `main` just reads the config,
//! enforces the startup invariants, prints the pairing QR, and serves the router.

use std::path::Path;

use jesse_bridge::{
    app, binary_exists, build_apns, env_truthy, is_bind_allowed, manual_pairing_lines,
    pairing_payload, show_token_opt_in, spawn_eviction_task, AppState, Config,
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
    // tailnet; the ts.net name has DNS quirks per STATUS.md). Override with
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
    axum::serve(listener, app(state))
        .await
        .expect("server error");
}
