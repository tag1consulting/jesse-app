use crate::*;

// ---- The build capability ------------------------------------------------------
//
// The child can write a correct patch and, until this module existed, could not compile it.
// That gap is why a code change could not be finished from the phone at all: this project's
// definition of done is a green build, and nothing in the allowlist could produce one.
//
// # Why this is not a Bash grant, and why no narrowing of one would have done
//
// The obvious fix is `Bash(cargo:*)` (or `Bash(xcodebuild:*)`). SECURITY.md records why the
// obvious fix is wrong, measured rather than argued: on 2026-08-14 a batch of shell verbs was
// granted, probed, and withdrawn the same day, because **the vault write boundary is enforced
// by exactly one thing — the path scope on `Edit`** — and every Bash grant writes through
// Bash, which that scope never touches. `duckdb` was withdrawn because its CLI is a shell;
// `node --check` was withdrawn because the free tail can supply a flag that loads another
// file. A build verb is strictly worse than everything on that list:
//
//   * it takes destination paths directly (`--target-dir`, `-derivedDataPath`, and for
//     xcodebuild any `SETTING=value` override such as `SYMROOT`);
//   * it executes arbitrary code BY DESIGN — `build.rs`, proc macros, a `Package.swift`
//     (which is an executable Swift program), package plugins and test targets all run as
//     the invoking user during an ordinary build.
//
// So `Bash(cargo:*)` is a grant of `bash`, and it would make every deliberate omission in the
// allowlist decorative. Pinning a wrapper script does not help either: the pinned-script
// grants are already recorded as WRITE-THEN-EXECUTE paths, and a build wrapper is worse
// still, because **building source the child can edit IS arbitrary code execution with no
// rewrite of the wrapper needed at all.**
//
// The capability therefore cannot be made safe by narrowing a string. It is made safe — to
// the extent it is — by ISOLATION, and the shape of the tool is chosen to leave the child no
// string to narrow:
//
//   * every operation is a variant of [`BuildOp`], a CLOSED set;
//   * every path, subcommand and flag is a compile-time constant reached from that variant;
//   * **no value from the child ever reaches the command line.** The MCP tools take an
//     EMPTY argument object (see `jesse-build-mcp`), so there is no free tail to abuse —
//     which is the one structural difference between this and `Bash(cargo:*)`.
//
// # The isolation boundary
//
// The build runs under a macOS sandbox profile ([`build_sandbox_profile`]) that DENIES ALL
// FILE WRITES except to the scratch root and the two per-user Darwin scratch directories.
// The vault, the checkout being built, the bridge's state directory and the whole home
// directory are read-only to it, verified live (see SECURITY.md).
//
// NETWORK IS PER OPERATION, and the distinction is load-bearing. A COMPILE gets no socket at
// all, which is why every operation also passes `--offline --locked` — it could not reach a
// registry even if it tried. A TEST RUN gets sockets scoped to THIS HOST, because the
// integration suite stands up mock HTTP helpers on `127.0.0.1` and cannot run without them.
// Neither can leave the machine. See [`build_sandbox_profile`] for what "this host" really
// covers, which is more than `127.0.0.1`.
//
// The dedicated non-privileged unix user, which would be the stronger boundary, is NOT what
// this implements; it needs a local account and a sudoers rule, both of which are root-owned
// host provisioning rather than repo content. SECURITY.md names that as the residual gap.

/// The scratch root every build writes into — target directories, temp files, logs.
///
/// A MACRO rather than a plain `const` for the same reason `home_assistant_mcp_url!` is one:
/// the argv consts below are built with `concat!`, which accepts a macro expanding to a
/// literal but cannot accept a `const` item. This keeps the path to a SINGLE occurrence in
/// the tree instead of one in each argv and one in the profile.
///
/// It is under `/private/tmp` (the canonical spelling of `/tmp`, which is a symlink — and the
/// sandbox matches CANONICAL paths, so `/tmp/...` here would silently match nothing) for the
/// same reason the browser server's `--output-dir` is: it must read identically on every
/// deployment. A home directory here would pin the posture to one machine and trip
/// `scripts/ci-guards.sh`.
macro_rules! build_scratch_root {
    () => {
        "/private/tmp/jesse-build"
    };
}

/// See [`build_scratch_root`].
pub const BUILD_SCRATCH_ROOT: &str = build_scratch_root!();

/// Where the repository under build lives, relative to the vault root.
///
/// This is the SAME path the review-checkout convention already produces
/// (`Code/<host>/<owner>/<repo>`, a pure function of the clone URL), so a build acts on the
/// tree the child already clones and reads — no second checkout, no new convention.
///
/// It is relative to the vault rather than absolute for the reason every other path in the
/// containment story is: an absolute path would name one home directory.
pub const BUILD_CHECKOUT_REL: &str = "Code/github.com/tag1consulting/jesse-app";

/// How much of each stream the child is shown, per stream.
///
/// A runaway build emits megabytes; a turn must not be flooded by it. The TAIL is kept rather
/// than the head because a build's verdict — the error, the failing test, the summary line —
/// is at the end. [`read_tail`] enforces this while the process is still running, so the
/// memory ceiling holds even for output that never stops.
pub const BUILD_OUTPUT_TAIL_BYTES: usize = 16 * 1024;

/// ONE build at a time, process-wide.
///
/// Two turns building the same tree would interleave writes into one target directory and
/// produce a verdict describing neither. `const_new` so it needs no initialization dance.
static BUILD_SLOT: Semaphore = Semaphore::const_new(1);

/// The closed set of build operations.
///
/// A CLOSED SET IS THE WHOLE DESIGN. If an operation ever needs a choice, it becomes another
/// variant here — never a string parameter that becomes an argument, which is the property
/// that separates this from the shell verb it replaces.
///
/// **The app targets are deliberately absent, and that is a measured blocker rather than an
/// omission.** `xcodebuild` cannot be run inside this sandbox at all: SwiftPM evaluates
/// `Package.swift` inside its OWN `sandbox-exec` invocation, and macOS refuses to nest one
/// sandbox inside another — the build dies at package resolution with
/// `sandbox-exec: sandbox_apply: Operation not permitted`, and `xcodebuild` exposes no flag
/// to disable that inner sandbox. Running it UNSANDBOXED is exactly the `bash`-equivalent
/// grant this module exists to avoid. See SECURITY.md for the full measurement and for the
/// route that remains open to the app (push the branch; let CI build it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildOp {
    /// `cargo build` for the Rust bridge.
    BuildBridge,
    /// `cargo test` for the Rust bridge.
    TestBridge,
}

impl BuildOp {
    /// Every operation, in the order the tool list advertises them.
    pub const ALL: [BuildOp; 2] = [BuildOp::BuildBridge, BuildOp::TestBridge];

    /// The MCP tool name, WITHOUT the `mcp__build__` prefix the harness adds.
    ///
    /// Exhaustive on purpose — never a `_` arm. A new variant must be given a name here, and
    /// the compiler is the cheapest place to be told it has none.
    pub fn tool_name(&self) -> &'static str {
        match self {
            BuildOp::BuildBridge => "build_bridge",
            BuildOp::TestBridge => "test_bridge",
        }
    }

    /// Parse a tool name back (the `tools/call` dispatch).
    pub fn parse(name: &str) -> Option<BuildOp> {
        BuildOp::ALL.into_iter().find(|op| op.tool_name() == name)
    }

    /// What the child is told the tool does. Written for a reader who must decide whether to
    /// call it, so it states the two things that surprise: no arguments, and no network.
    pub fn description(&self) -> &'static str {
        match self {
            BuildOp::BuildBridge => {
                "Compile the Rust bridge (cargo build) in the jesse-app checkout. \
                 Takes no arguments. Runs offline against the committed Cargo.lock, so a \
                 change that adds or updates a dependency cannot be built here."
            }
            BuildOp::TestBridge => {
                "Run the Rust bridge's test suite (cargo test) in the jesse-app checkout. \
                 Takes no arguments. Runs offline against the committed Cargo.lock."
            }
        }
    }

    /// The FULL command line, program first. Every token is a compile-time constant.
    ///
    /// `--offline` and `--locked` are not tuning. Offline because the sandbox denies network
    /// anyway, so a build that reached for the registry would hang or fail obscurely rather
    /// than say what is wrong; locked so a stale or edited `Cargo.lock` is a crisp error
    /// instead of a silent dependency change. Together they mean a dependency edit is NOT
    /// buildable through this tool, which is a deliberate limit and is documented as one.
    pub fn argv(&self) -> &'static [&'static str] {
        match self {
            BuildOp::BuildBridge => &[
                "cargo",
                "build",
                "--offline",
                "--locked",
                "--target-dir",
                concat!(build_scratch_root!(), "/bridge-target"),
            ],
            BuildOp::TestBridge => &[
                "cargo",
                "test",
                "--offline",
                "--locked",
                "--target-dir",
                concat!(build_scratch_root!(), "/bridge-target"),
            ],
        }
    }

    /// The working directory, relative to the checkout root. A constant, like everything else.
    ///
    /// `bridge` rather than the repo root because `bridge/` is deliberately EXCLUDED from the
    /// root cargo workspace (it carries its own `Cargo.lock`, and CI builds it from
    /// `working-directory: bridge`), so this is the directory that reproduces CI byte for byte.
    pub fn subdir(&self) -> &'static str {
        match self {
            BuildOp::BuildBridge | BuildOp::TestBridge => "bridge",
        }
    }

    /// Wall-clock ceiling. On expiry the whole PROCESS GROUP is killed, not just the leader —
    /// `cargo` spawns `rustc` and test binaries, and killing only the leader would leave them
    /// holding the target directory and the slot.
    pub fn timeout(&self) -> Duration {
        match self {
            BuildOp::BuildBridge => Duration::from_secs(900),
            BuildOp::TestBridge => Duration::from_secs(1_800),
        }
    }

    /// Whether this operation needs to open sockets ON THIS MACHINE.
    ///
    /// A COMPILE NEVER DOES, and gets no network at all. A TEST RUN does: the bridge's own
    /// integration suite stands up mock HTTP helpers on `127.0.0.1:0` and talks to them, and
    /// with sockets denied five vision tests fail with `PermissionDenied` — which made
    /// `test_bridge` report a RED suite on a tree that is green everywhere else. That is
    /// worse than useless: a verdict tool that always says FAILED trains its reader to
    /// ignore it.
    ///
    /// Split per operation rather than granted globally so the compile path keeps the
    /// stronger boundary it can afford. See [`build_sandbox_profile`] for exactly how far
    /// "local" reaches, which is further than the word suggests.
    pub fn needs_local_sockets(&self) -> bool {
        match self {
            BuildOp::BuildBridge => false,
            BuildOp::TestBridge => true,
        }
    }

    /// Whether this operation needs the SHARED `/private/tmp`, not just its own scratch root.
    ///
    /// A COMPILE DOES NOT. A test run does, and for a reason that cannot be configured away:
    /// the write-lock tests build a unix domain socket path, `sun_path` is capped at ~104
    /// bytes, and the per-user Darwin temp directory is long enough to blow through that on
    /// its own. So those tests hardcode `/tmp/jwl-<pid>-<nanos>` deliberately, with a comment
    /// saying why. `TMPDIR` does not redirect them, because they never consult it.
    ///
    /// This is the LOOSER of the two postures and it is worth naming plainly: a test run can
    /// drop files anywhere under `/private/tmp`, which other processes on this machine also
    /// use. It is still not the vault, the checkout, the bridge state directory or the home
    /// directory — those stay denied under both postures.
    pub fn needs_shared_tmp(&self) -> bool {
        match self {
            BuildOp::BuildBridge => false,
            BuildOp::TestBridge => true,
        }
    }
}

/// What one operation amounted to. The child sees exactly this, rendered as text.
#[derive(Debug, Clone)]
pub struct BuildOutcome {
    pub op: BuildOp,
    /// Whether the operation SUCCEEDED — the process exited zero. For `cargo test` that means
    /// every test passed.
    pub passed: bool,
    /// The exit code, or `None` if the process was signalled (including by our own timeout).
    pub exit_code: Option<i32>,
    /// Whether [`BuildOp::timeout`] expired and the process group was killed.
    pub timed_out: bool,
    /// The last [`BUILD_OUTPUT_TAIL_BYTES`] of each stream.
    pub stdout_tail: String,
    pub stderr_tail: String,
    pub duration_ms: u128,
    /// Set when the operation could not be ATTEMPTED (no checkout, spawn failed). Distinct
    /// from a failing build, which is a real verdict.
    pub error: Option<String>,
}

impl BuildOutcome {
    /// The failure shape for "could not even start". `passed` is false and the reason is
    /// stated, so a caller never has to infer it from an empty tail.
    fn unattempted(op: BuildOp, error: String) -> BuildOutcome {
        BuildOutcome {
            op,
            passed: false,
            exit_code: None,
            timed_out: false,
            stdout_tail: String::new(),
            stderr_tail: String::new(),
            duration_ms: 0,
            error: Some(error),
        }
    }

    /// The structured text the child is handed. Deliberately a fixed shape with the VERDICT
    /// first: the useful signal is pass/fail, and a model reading a wall of build log should
    /// not have to derive it.
    pub fn render(&self) -> String {
        let mut s = String::new();
        if let Some(err) = &self.error {
            s.push_str(&format!("{}: NOT RUN — {err}\n", self.op.tool_name()));
            return s;
        }
        let verdict = if self.timed_out {
            "TIMED OUT".to_string()
        } else if self.passed {
            "PASSED".to_string()
        } else {
            match self.exit_code {
                Some(c) => format!("FAILED (exit {c})"),
                None => "FAILED (killed by signal)".to_string(),
            }
        };
        s.push_str(&format!(
            "{}: {verdict} in {}ms\n",
            self.op.tool_name(),
            self.duration_ms
        ));
        if !self.stdout_tail.is_empty() {
            s.push_str(&format!(
                "\n--- stdout (last {} bytes) ---\n{}\n",
                BUILD_OUTPUT_TAIL_BYTES, self.stdout_tail
            ));
        }
        if !self.stderr_tail.is_empty() {
            s.push_str(&format!(
                "\n--- stderr (last {} bytes) ---\n{}\n",
                BUILD_OUTPUT_TAIL_BYTES, self.stderr_tail
            ));
        }
        s
    }
}

/// Read a stream to EOF while keeping only its last `max` bytes.
///
/// The cap is enforced DURING the read, not after, so a build that never stops talking cannot
/// grow this buffer without bound. The buffer is allowed to reach `2 * max` before it is
/// halved, which amortizes the copy to O(1) per byte instead of memmoving on every chunk.
///
/// The tail is cut on a UTF-8 boundary at the end (`from_utf8_lossy` would otherwise render a
/// leading partial code point as a replacement character).
async fn read_tail<R>(mut reader: R, max: usize) -> String
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() > max.saturating_mul(2) {
                    let cut = buf.len() - max;
                    buf.drain(..cut);
                }
            }
        }
    }
    if buf.len() > max {
        let cut = buf.len() - max;
        buf.drain(..cut);
    }
    // Drop a leading partial UTF-8 sequence so the first character is not a replacement char.
    let start = buf
        .iter()
        .position(|b| (*b as i8) >= -0x40)
        .unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[start..]).into_owned()
}

/// A `confstr(3)` directory, canonicalized.
///
/// CANONICALIZED IS LOAD-BEARING. These come back as `/var/folders/...`, and `/var` is a
/// symlink to `/private/var`; the macOS sandbox matches the RESOLVED path, so an
/// uncanonicalized `subpath` here matches nothing at all and the rule silently does nothing.
/// That exact mistake cost a full debugging cycle when this was written — the profile looked
/// correct and every write to the directory was still refused.
#[cfg(target_os = "macos")]
fn confstr_dir(name: libc::c_int) -> Option<PathBuf> {
    // SAFETY: the two-call confstr idiom — ask for the size, then fill a buffer of that size.
    // `confstr` returns the number of bytes needed INCLUDING the NUL, or 0 on error.
    unsafe {
        let need = libc::confstr(name, std::ptr::null_mut(), 0);
        if need == 0 {
            return None;
        }
        let mut buf = vec![0u8; need];
        // NOT named `got`: `scripts/ci-guards.sh` flags any local by that name compared with
        // `==`, because that is the shape the hand-rolled bearer-token comparison had. The
        // guard is deliberately broad; this is a rename, not an exemption.
        let filled = libc::confstr(name, buf.as_mut_ptr() as *mut libc::c_char, buf.len());
        if filled == 0 || filled > buf.len() {
            return None;
        }
        buf.truncate(filled.saturating_sub(1)); // drop the trailing NUL
        let s = String::from_utf8(buf).ok()?;
        std::fs::canonicalize(s.trim_end_matches('/')).ok()
    }
}

/// The per-user Darwin temp and cache directories, canonicalized.
///
/// THESE ARE WRITABLE AND THAT IS NOT DECORATION — it was measured. With only the scratch
/// root writable, `cargo test` fails: `sips` (which the vision tests shell out to for a HEIC
/// fixture) writes into the per-user cache directory, and nothing can redirect it there —
/// the path comes from `confstr`, not from `TMPDIR`, so it cannot be pointed at the scratch.
/// They are per-user SCRATCH directories, not the vault and not the bridge's state directory;
/// the cost of granting them is recorded in SECURITY.md rather than hidden here.
#[cfg(target_os = "macos")]
fn darwin_scratch_dirs() -> Vec<PathBuf> {
    [
        confstr_dir(libc::_CS_DARWIN_USER_TEMP_DIR),
        confstr_dir(libc::_CS_DARWIN_USER_CACHE_DIR),
    ]
    .into_iter()
    .flatten()
    .collect()
}

/// Non-macOS: there are no Darwin per-user directories and no `sandbox-exec` either.
///
/// THE CAPABILITY IS macOS-ONLY IN PRACTICE — the bridge is a macOS daemon and the isolation
/// boundary is a macOS sandbox profile. This arm exists so the crate still COMPILES on the
/// Linux runner that builds, tests, clippies and audits it in CI; a build attempted there
/// fails at spawn and is reported as `NOT RUN`, which is the honest answer rather than a
/// silently unsandboxed one.
#[cfg(not(target_os = "macos"))]
fn darwin_scratch_dirs() -> Vec<PathBuf> {
    Vec::new()
}

/// Quote a path into a sandbox-profile string literal.
///
/// The profile is SLisp; a `"` or `\` in a path would end the literal early and change the
/// meaning of the rule. Real build paths contain neither, but a profile that can be broken by
/// its own input is not a boundary, so it is escaped rather than trusted.
fn sb_quote(p: &Path) -> String {
    let s = p.to_string_lossy();
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// The sandbox profile a build runs under.
///
/// `(deny default)` first, so every operation class is denied unless named — including
/// **network, which is never allowed**, so a build cannot fetch a dependency or exfiltrate
/// what it read. What is then allowed is the minimum a real toolchain needs, and each line
/// was added because something measurably failed without it:
///
///   * `process-exec`/`process-fork` — `cargo` spawns `rustc`, linkers and test binaries.
///   * `mach-lookup`, `sysctl-read`, `signal` — ordinary process plumbing.
///   * `iokit-open`/`iokit-get-properties` and `ipc-posix-shm*` — **the HEIC test.** `sips`
///     encodes HEIC on the hardware HEVC encoder, which it reaches through IOKit; without
///     these two lines `cargo test` fails one test and the tool reports a red suite on a tree
///     that is actually green. Found by bisecting the profile, not by reading a doc.
///   * `file-read*` — UNRESTRICTED, and named as an open risk rather than a decision made
///     quietly. Restricting it was attempted and abandoned: the toolchain reads from enough
///     places that an allowlist was fragile, and it buys little here because the allowlist
///     already grants the child unscoped `Bash(cat:*)`, `Bash(head:*)` and `Bash(tail:*)` —
///     so the build adds no read class the child did not already have.
///   * the three `/dev` nodes — `/dev/null` above all; a toolchain that cannot open it dies
///     in ways that look like anything but the real cause.
///
/// Writes are denied everywhere except `scratch` and `darwin`. The vault, the checkout, the
/// bridge state directory and the home directory are all read-only to a build.
///
/// # `local_sockets` — what "local" actually means here
///
/// With it FALSE (a compile) there is no network allowance of any kind and every socket
/// operation fails. With it TRUE (a test run) three rules are added, scoped to `localhost`.
///
/// **`localhost` in a sandbox filter does NOT mean `127.0.0.1`. It means any address
/// belonging to THIS HOST** — measured, not assumed: under a `localhost`-scoped outbound rule
/// a connection to this machine's tailnet address succeeded. So a test run can reach services
/// listening on this box, on any of its own interfaces. What it still cannot do is leave the
/// machine: a connection to `1.1.1.1:443` is refused with EPERM. That is the boundary this
/// buys — **no exfiltration off-box** — and it is stated in those terms rather than as
/// "loopback only", which would be false.
///
/// **Do not "simplify" these three rules into `(allow network* (local ip "localhost:*")
/// (remote ip "localhost:*"))`.** That spelling was probed alongside them and it REACHED THE
/// INTERNET — the wildcard verb does not carry the filters the way the individual verbs do.
/// It looks tighter, reads tighter, and is wide open.
pub fn build_sandbox_profile(
    scratch: &Path,
    darwin: &[PathBuf],
    local_sockets: bool,
    shared_tmp: bool,
) -> String {
    let mut p = String::new();
    p.push_str("(version 1)\n");
    p.push_str("(deny default)\n");
    p.push_str("(allow process-exec process-fork sysctl-read mach-lookup signal)\n");
    p.push_str("(allow iokit-open iokit-get-properties)\n");
    p.push_str("(allow ipc-posix-shm*)\n");
    p.push_str("(allow file-read*)\n");
    p.push_str(&format!(
        "(allow file-write* (subpath \"{}\"))\n",
        sb_quote(scratch)
    ));
    if shared_tmp {
        p.push_str("(allow file-write* (subpath \"/private/tmp\"))\n");
    }
    for d in darwin {
        p.push_str(&format!(
            "(allow file-write* (subpath \"{}\"))\n",
            sb_quote(d)
        ));
    }
    p.push_str(
        "(allow file-write-data (literal \"/dev/null\") (literal \"/dev/tty\") \
         (literal \"/dev/dtracehelper\"))\n",
    );
    if local_sockets {
        // ALL THREE ARE REQUIRED and that was measured, not read: with `network-bind` and
        // `network-outbound` alone a `bind()` on 127.0.0.1 still fails with EPERM —
        // `network-inbound` is what `accept()` needs.
        p.push_str("(allow network-bind (local ip \"localhost:*\"))\n");
        p.push_str("(allow network-inbound (local ip \"localhost:*\"))\n");
        p.push_str("(allow network-outbound (remote ip \"localhost:*\"))\n");
    }
    p
}

/// The environment a build gets — EXPLICIT, never inherited.
///
/// THIS IS A SECURITY BOUNDARY, NOT TIDINESS. The bridge's own environment carries every MCP
/// server credential it forwards (Google, GitHub, Fastmail, UniFi, Home Assistant, Slack…),
/// because `export_mcp_server_env` puts them there and nothing clears them. A build is
/// arbitrary code; handing it that environment would hand it every one of those secrets, and
/// no sandbox profile would take them back. So the command is built with `env_clear()` and
/// exactly these five variables.
///
/// `HOME` is the REAL home and must be: `cargo` resolves the toolchain and the crate registry
/// under it, and a synthetic home breaks the build outright (`rustup could not choose a
/// version of cargo to run`, measured). It is safe to name because the sandbox makes the home
/// directory READ-ONLY to the build — the grant is reading, which the child already has.
fn build_env(home: &str, scratch: &Path) -> Vec<(String, String)> {
    vec![
        (
            "PATH".to_string(),
            format!("{home}/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
        ),
        ("HOME".to_string(), home.to_string()),
        (
            "TMPDIR".to_string(),
            scratch.join("tmp").to_string_lossy().into_owned(),
        ),
        // Colour escapes would be noise in a tail the model has to read.
        ("CARGO_TERM_COLOR".to_string(), "never".to_string()),
        ("LANG".to_string(), "en_US.UTF-8".to_string()),
    ]
}

/// Run one operation and return its structured verdict.
///
/// Serialized against every other build by [`BUILD_SLOT`]; the wait is inside the function so
/// a caller cannot forget it.
pub async fn run_build_op(op: BuildOp, vault: &str, home: &str) -> BuildOutcome {
    let _permit = match BUILD_SLOT.acquire().await {
        Ok(p) => p,
        Err(_) => return BuildOutcome::unattempted(op, "build slot closed".to_string()),
    };

    let workdir = PathBuf::from(vault)
        .join(BUILD_CHECKOUT_REL)
        .join(op.subdir());
    if !workdir.is_dir() {
        return BuildOutcome::unattempted(
            op,
            format!(
                "no checkout at {} — clone the repository there first",
                workdir.display()
            ),
        );
    }

    let scratch = PathBuf::from(BUILD_SCRATCH_ROOT);
    if let Err(e) = std::fs::create_dir_all(scratch.join("tmp")) {
        return BuildOutcome::unattempted(op, format!("cannot create scratch dir: {e}"));
    }

    let profile = build_sandbox_profile(
        &scratch,
        &darwin_scratch_dirs(),
        op.needs_local_sockets(),
        op.needs_shared_tmp(),
    );
    let argv = op.argv();

    // `sandbox-exec -p <profile>` rather than `-f <file>`: a file would be one more thing to
    // create, keep in sync and protect from the very build it constrains.
    let mut cmd = Command::new("/usr/bin/sandbox-exec");
    cmd.arg("-p").arg(&profile).arg(argv[0]).args(&argv[1..]);
    cmd.current_dir(&workdir);
    cmd.env_clear();
    for (k, v) in build_env(home, &scratch) {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // Its own process group, so the timeout can kill the whole tree (`cargo` → `rustc` →
    // test binaries) rather than just the leader.
    cmd.process_group(0);

    let started = Instant::now();
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return BuildOutcome::unattempted(op, format!("cannot spawn sandbox-exec: {e}")),
    };
    let pid = child.id().unwrap_or(0) as i32;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let out_task = tokio::spawn(async move {
        match stdout {
            Some(s) => read_tail(s, BUILD_OUTPUT_TAIL_BYTES).await,
            None => String::new(),
        }
    });
    let err_task = tokio::spawn(async move {
        match stderr {
            Some(s) => read_tail(s, BUILD_OUTPUT_TAIL_BYTES).await,
            None => String::new(),
        }
    });

    let mut timed_out = false;
    let status = match timeout(op.timeout(), child.wait()).await {
        Ok(r) => r.ok(),
        Err(_) => {
            timed_out = true;
            kill_process_group(pid);
            child.wait().await.ok()
        }
    };

    let stdout_tail = out_task.await.unwrap_or_default();
    let stderr_tail = err_task.await.unwrap_or_default();

    BuildOutcome {
        op,
        passed: !timed_out && status.map(|s| s.success()).unwrap_or(false),
        exit_code: status.and_then(|s| s.code()),
        timed_out,
        stdout_tail,
        stderr_tail,
        duration_ms: started.elapsed().as_millis(),
        error: None,
    }
}

/// SIGKILL a whole process group.
///
/// SIGKILL rather than SIGTERM because this runs only after the wall-clock ceiling has already
/// expired: a build that ignored the deadline has had its chance to exit politely, and a
/// second grace period would just hold the slot longer.
fn kill_process_group(pid: i32) {
    if pid <= 0 {
        return;
    }
    // SAFETY: `killpg` on a pgid this process created. A failure (the group already exited) is
    // the expected race and is ignored.
    unsafe {
        libc::killpg(pid, libc::SIGKILL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE PROPERTY THE WHOLE MODULE EXISTS FOR: no operation's command line carries anything
    /// that could have come from a caller. If this ever fails, the tool has become the shell
    /// verb it was built to replace.
    #[test]
    fn no_operation_takes_an_argument() {
        for op in BuildOp::ALL {
            for tok in op.argv() {
                assert!(
                    !tok.contains("{}") && !tok.contains('$'),
                    "{}: argv token {tok:?} looks interpolated — every token must be a constant",
                    op.tool_name()
                );
            }
            // The target dir is the only path in an argv and it must stay inside the scratch.
            if let Some(i) = op.argv().iter().position(|t| *t == "--target-dir") {
                let dir = op.argv()[i + 1];
                assert!(
                    dir.starts_with(BUILD_SCRATCH_ROOT),
                    "{}: --target-dir {dir} escapes the scratch root",
                    op.tool_name()
                );
            }
        }
    }

    /// Every operation is offline and locked, so no build can reach the network or silently
    /// change a dependency. Asserted per operation rather than trusted to review.
    #[test]
    fn every_operation_is_offline_and_locked() {
        for op in BuildOp::ALL {
            assert!(
                op.argv().contains(&"--offline"),
                "{} must be --offline",
                op.tool_name()
            );
            assert!(
                op.argv().contains(&"--locked"),
                "{} must be --locked",
                op.tool_name()
            );
        }
    }

    /// Tool names round-trip, and nothing outside the closed set parses. `tools/call`
    /// dispatches on this, so an unknown name must not resolve to an operation.
    #[test]
    fn tool_names_round_trip_and_nothing_else_parses() {
        for op in BuildOp::ALL {
            assert_eq!(BuildOp::parse(op.tool_name()), Some(op));
        }
        for bogus in ["", "build", "build_app", "test_app", "BUILD_BRIDGE", "sh"] {
            assert_eq!(BuildOp::parse(bogus), None, "{bogus} must not parse");
        }
    }

    /// The profile denies by default, never allows network, and confines writes to the
    /// directories it was given. This is the boundary in one assertion.
    /// A COMPILE gets no socket of any kind. This is the tighter of the two postures and the
    /// one that must not drift: nothing about compiling needs the network, so any `network`
    /// line appearing on this path is a mistake.
    #[test]
    fn the_profile_denies_by_default_and_a_compile_gets_no_network() {
        let p = build_sandbox_profile(Path::new("/private/tmp/jesse-build"), &[], false, false);
        assert!(p.contains("(deny default)"));
        assert!(
            !p.contains("network"),
            "a compile must never allow network:\n{p}"
        );
        // Exactly one write grant when no Darwin dirs are supplied, and it is the scratch.
        let writes: Vec<&str> = p
            .lines()
            .filter(|l| l.starts_with("(allow file-write* "))
            .collect();
        assert_eq!(writes.len(), 1, "unexpected write grants: {writes:?}");
        assert!(writes[0].contains("/private/tmp/jesse-build"));
    }

    /// A path that tries to close the string literal early is escaped rather than obeyed.
    #[test]
    fn a_quote_in_a_path_cannot_break_out_of_the_profile() {
        let p = build_sandbox_profile(
            Path::new("/tmp/a\") (allow file-write* (subpath \"/"),
            &[],
            false,
            false,
        );
        // The injected `(allow ...)` must not appear as its own rule.
        let writes: Vec<&str> = p
            .lines()
            .filter(|l| l.starts_with("(allow file-write* "))
            .collect();
        assert_eq!(
            writes.len(),
            1,
            "quote injection created a rule: {writes:?}"
        );
        assert!(
            p.contains("\\\""),
            "the quote should have been escaped:\n{p}"
        );
    }

    /// A TEST RUN gets exactly three socket rules, all `localhost`-scoped, and NEVER the
    /// `network*` wildcard form — which was measured to reach the open internet despite
    /// carrying the same-looking filters.
    #[test]
    fn a_test_run_gets_local_sockets_and_never_the_wildcard_form() {
        let p = build_sandbox_profile(Path::new("/private/tmp/jesse-build"), &[], true, true);
        for verb in ["network-bind", "network-inbound", "network-outbound"] {
            assert!(p.contains(verb), "{verb} missing:\n{p}");
        }
        assert!(
            !p.contains("(allow network* "),
            "the wildcard network verb does not carry its filters — it reached the internet \
             when probed. Never use it here:\n{p}"
        );
        // Every network rule must be localhost-scoped; an unscoped one would be off-box reach.
        for line in p.lines().filter(|l| l.contains("network")) {
            assert!(
                line.contains("localhost:*"),
                "unscoped network rule {line:?} — this must never leave the machine"
            );
        }
    }

    /// The two operations differ in exactly one way, and it is deliberate. If a compile ever
    /// starts asking for sockets, that is a change worth failing a test over.
    #[test]
    fn only_the_test_operation_asks_for_sockets() {
        assert!(!BuildOp::BuildBridge.needs_local_sockets());
        assert!(BuildOp::TestBridge.needs_local_sockets());
    }

    /// The environment is the explicit five, and carries NO credential the bridge holds.
    /// `env_clear` plus this list is what keeps a build from inheriting every MCP secret.
    #[test]
    fn the_build_environment_is_explicit_and_carries_no_credentials() {
        let env = build_env("/home/someone", Path::new("/private/tmp/jesse-build"));
        let keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(
            keys,
            vec!["PATH", "HOME", "TMPDIR", "CARGO_TERM_COLOR", "LANG"]
        );
        for (k, v) in &env {
            assert!(
                !k.starts_with("JESSE_") && !k.contains("TOKEN") && !k.contains("SECRET"),
                "{k} must not be forwarded to a build"
            );
            assert!(!v.contains("Bearer "), "{k} carries a credential");
        }
    }

    /// The tail is bounded and keeps the END of the stream — the half a build's verdict is in.
    #[tokio::test]
    async fn output_is_bounded_and_keeps_the_tail() {
        let big = "x".repeat(100_000) + "THE-VERDICT";
        let tail = read_tail(big.as_bytes(), 1_024).await;
        assert!(tail.len() <= 1_024, "tail was {} bytes", tail.len());
        assert!(
            tail.ends_with("THE-VERDICT"),
            "the end of the stream was lost"
        );
    }

    /// A tail cut mid-code-point renders as text, not as a leading replacement character.
    #[tokio::test]
    async fn a_tail_cut_inside_a_code_point_is_trimmed_to_a_boundary() {
        // 'é' is two bytes; cutting to an odd length lands inside one.
        let s = "é".repeat(100);
        let tail = read_tail(s.as_bytes(), 51).await;
        assert!(
            !tail.starts_with('\u{FFFD}'),
            "leading partial code point was not trimmed: {tail:?}"
        );
    }

    /// A missing checkout is reported as NOT RUN with the path, never as a failing build —
    /// the two mean completely different things to whoever reads the turn.
    #[tokio::test]
    async fn a_missing_checkout_is_not_run_rather_than_failed() {
        let out = run_build_op(BuildOp::BuildBridge, "/nonexistent-vault", "/nonexistent").await;
        assert!(!out.passed);
        assert!(out.error.is_some());
        let rendered = out.render();
        assert!(rendered.contains("NOT RUN"), "{rendered}");
        assert!(rendered.contains("no checkout at"), "{rendered}");
    }

    /// The rendered verdict leads with pass/fail, so a model does not have to infer it from
    /// the log.
    #[test]
    fn the_verdict_comes_first() {
        let out = BuildOutcome {
            op: BuildOp::TestBridge,
            passed: false,
            exit_code: Some(101),
            timed_out: false,
            stdout_tail: "some log".to_string(),
            stderr_tail: String::new(),
            duration_ms: 42,
            error: None,
        };
        let r = out.render();
        assert!(r.starts_with("test_bridge: FAILED (exit 101)"), "{r}");
    }
}
