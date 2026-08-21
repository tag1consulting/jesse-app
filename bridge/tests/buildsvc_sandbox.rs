//! The build capability's ISOLATION BOUNDARY, probed live against the real sandbox.
//!
//! `buildsvc`'s unit tests check the profile's TEXT. Text is not a boundary. These tests run
//! `sandbox-exec` with the profile the bridge actually generates and check, out of band,
//! whether a write landed — the same "ground truth, never the child's word" rule the
//! containment battery is built on.
//!
//! The defect these guard against is the one this whole capability is a workaround for: a
//! build is arbitrary code, and the only thing standing between it and the vault is this
//! profile. A silent regression here — a path spelled `/tmp` instead of `/private/tmp`, an
//! `(allow file-write*)` that grew a subpath, a `(deny default)` that got reordered — would
//! leave the tools looking identical and the boundary gone.
//!
//! macOS-ONLY, and skipped rather than failed elsewhere: `sandbox-exec` does not exist on the
//! Linux runner that builds and tests this crate in CI. That means **CI does not run these** —
//! they are a local gate, and the containment battery in `bridge/containment.toml` is the
//! recorded one. Stated here so nobody mistakes a green CI badge for a probed boundary.

#![cfg(target_os = "macos")]

use jesse_bridge::{build_sandbox_profile, BUILD_SCRATCH_ROOT};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Run `touch <target>` under the generated profile. Returns whether the file EXISTS
/// afterwards — ground truth, not the exit status, because a tool that fails for an unrelated
/// reason must not read as containment.
fn touch_under_sandbox(target: &Path) -> bool {
    let _ = std::fs::remove_file(target);
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[], false, false);
    let status = Command::new("/usr/bin/sandbox-exec")
        .arg("-p")
        .arg(&profile)
        .arg("/usr/bin/touch")
        .arg(target)
        .status();
    let landed = target.exists();
    // Leave nothing behind either way.
    let _ = std::fs::remove_file(target);
    assert!(status.is_ok(), "sandbox-exec did not run at all");
    landed
}

/// The scratch root must be WRITABLE, or the capability does not work at all. This is the
/// positive control: a battery that passes because everything is broken proves nothing.
#[test]
fn a_build_can_write_inside_the_scratch_root() {
    let scratch = PathBuf::from(BUILD_SCRATCH_ROOT);
    std::fs::create_dir_all(&scratch).expect("create scratch");
    assert!(
        touch_under_sandbox(&scratch.join("boundary-positive-control")),
        "the scratch root must be writable or no build can run"
    );
}

/// The three directories that matter, each probed by an actual attempted write.
///
/// `/tmp` is included deliberately even though it is a scratch area itself: it is the SIBLING
/// of the allowed subpath, so it is what catches a profile that accidentally grants the parent
/// rather than `/private/tmp/jesse-build`.
#[test]
fn a_build_cannot_write_outside_the_scratch_root() {
    let home = std::env::var("HOME").expect("HOME");
    let cases: Vec<(&str, PathBuf)> = vec![
        (
            "the scratch root's parent",
            PathBuf::from("/tmp/jesse-boundary-escape"),
        ),
        (
            "the home directory",
            PathBuf::from(&home).join("jesse-boundary-escape"),
        ),
        (
            "the bridge's state directory",
            PathBuf::from(&home).join(".jesse-bridge-boundary-escape"),
        ),
    ];
    for (what, target) in cases {
        assert!(
            !touch_under_sandbox(&target),
            "a build wrote into {what} ({}) — the isolation boundary is GONE",
            target.display()
        );
    }
}

/// The checkout a build compiles is READ-ONLY to it.
///
/// This is the one that distinguishes this design from `Bash(cargo:*)`. The child can edit the
/// checkout through its own scoped `Edit` grant — that is expected, and is the recorded
/// write-then-execute open — but the BUILD must not be able to rewrite the tree it is
/// compiling, or a single build could persist changes that no turn ever wrote.
#[test]
fn a_build_cannot_write_into_the_checkout_it_compiles() {
    // The crate's own directory stands in for the checkout: same shape, and it is guaranteed
    // to exist wherever this test runs.
    let checkout = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    assert!(
        !touch_under_sandbox(&checkout.join("jesse-boundary-escape")),
        "a build wrote into the tree it was compiling"
    );
}

/// The shared-`/tmp` widening belongs to the TEST posture only. A compile must keep the
/// tighter boundary — if this ever passes, the two postures have been collapsed into one.
#[test]
fn a_compile_still_cannot_write_to_shared_tmp() {
    // `touch_under_sandbox` builds the COMPILE profile, so this is the tight posture.
    assert!(
        !touch_under_sandbox(&PathBuf::from("/tmp/jesse-compile-tmp-escape")),
        "the compile posture gained the test posture's /tmp grant"
    );
}

/// A COMPILE gets no socket at all, checked by ATTEMPTING one rather than by reading the
/// profile. `(deny default)` is what denies it, so this also fails if someone reorders the
/// profile so a later blanket allow lands underneath.
#[test]
fn a_compile_cannot_open_any_socket() {
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[], false, false);
    // `nc -z` needs no DNS and no payload; loopback is enough to prove the class is denied,
    // and it cannot be confused with a network being merely unreachable.
    let out = Command::new("/usr/bin/sandbox-exec")
        .arg("-p")
        .arg(&profile)
        .arg("/usr/bin/nc")
        .args(["-z", "-w", "1", "127.0.0.1", "22"])
        .output()
        .expect("run nc under the sandbox");
    assert!(
        !out.status.success(),
        "a socket was opened under the compile profile — network is not denied"
    );
}

/// A TEST RUN can bind and accept on loopback — the property the bridge's own integration
/// suite needs, and whose absence made `test_bridge` report a red suite on a green tree.
///
/// The probe is a ONE-LINER on purpose: a `-c` program with indented blocks has to survive
/// Rust string escaping, and getting that wrong fails the test for a reason that has nothing
/// to do with the sandbox.
#[test]
fn a_test_run_can_bind_and_accept_on_loopback() {
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[], true, true);
    let out = Command::new("/usr/bin/sandbox-exec")
        .arg("-p")
        .arg(&profile)
        .arg("/usr/bin/python3")
        .arg("-c")
        .arg(
            "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1); \
             c=socket.socket(); c.settimeout(2); c.connect(s.getsockname()); s.accept(); \
             print('ok')",
        )
        .output()
        .expect("run python under the sandbox");
    assert!(
        out.status.success(),
        "a test run could not stand up a loopback mock server: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// …and STILL cannot leave the machine. This is the half of the socket grant that matters:
/// "local" reaches every address this host owns, but nothing beyond it, so a hostile test
/// cannot exfiltrate what `file-read*` let it read.
#[test]
fn a_test_run_still_cannot_reach_off_box() {
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[], true, true);
    let out = Command::new("/usr/bin/sandbox-exec")
        .arg("-p")
        .arg(&profile)
        .arg("/usr/bin/nc")
        .args(["-z", "-w", "3", "1.1.1.1", "443"])
        .output()
        .expect("run nc under the sandbox");
    assert!(
        !out.status.success(),
        "a test run reached the open internet — the socket grant is not host-scoped"
    );
}
