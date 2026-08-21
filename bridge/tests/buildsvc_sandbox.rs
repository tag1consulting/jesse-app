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
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[]);
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

/// Network is denied, and it is checked by ATTEMPTING one rather than by reading the profile.
///
/// `(deny default)` is what denies it, so this also fails if someone reorders the profile so
/// that a later blanket allow lands underneath. A build with network is a build that can
/// exfiltrate everything `file-read*` lets it read.
#[test]
fn a_build_cannot_reach_the_network() {
    let profile = build_sandbox_profile(Path::new(BUILD_SCRATCH_ROOT), &[]);
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
        "a socket was opened under the build profile — network is not denied"
    );
}
