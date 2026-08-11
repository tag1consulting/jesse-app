#!/usr/bin/env bash
#
# local-ci-macos.sh — run, on this Mac, the checks that .github/workflows/ios-ci.yml
# runs on a hosted macOS runner. Same checks, same order, same flags.
#
# THIS IS THE GATE FOR THE APP. The macOS job no longer runs on pull requests
# (hosted macOS minutes bill at 10x Linux, and that job was essentially the whole
# Actions bill), so nothing on GitHub will tell you the app is broken before your
# PR merges. This script is what tells you. The nightly run of ios-ci.yml is a
# backstop that reports up to a day late, not a gate.
#
# Usage:
#     scripts/local-ci-macos.sh
#
# It is also wired as a pre-push hook — install once per clone with:
#     scripts/install-hooks.sh
# after which every `git push` that touches Jesse/ or JesseKit/ runs it and is
# blocked if it fails.
#
# ESCAPE HATCHES (both leave you responsible for the nightly's verdict):
#     git push --no-verify        skip ALL pre-push checks, including the version
#                                 guard — the blunt instrument, avoid it
#     JESSE_SKIP_MAC_CI=1 git push  skip only this script, keep the version guard
#
# Exits non-zero on the first failing check and prints a PASS/FAIL summary of
# everything it got through.
#
# Requires: Xcode (not just Command Line Tools), and `jq`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# --- Toolchain -------------------------------------------------------------
#
# `xcode-select -p` commonly points at CommandLineTools on a dev Mac, where bare
# `xcodebuild` fails and `xcrun simctl` has no simulators. Point at the real
# Xcode for the duration of this script rather than asking for a sudo
# `xcode-select --switch` that changes the whole machine's state.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null || true)" in
    *Xcode*.app*) : ;;
    *)
      if [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
      fi
      ;;
  esac
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "local-ci-macos: xcodebuild is not usable." >&2
  echo "  Install Xcode (Command Line Tools alone are not enough), or set" >&2
  echo "  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "local-ci-macos: jq not found (used to resolve simulators and read test" >&2
  echo "  results, exactly as CI does). Install it: brew install jq" >&2
  exit 1
fi

echo "local-ci-macos: $(xcodebuild -version | head -1), DEVELOPER_DIR=$(xcode-select -p)"

# --- Step plumbing ---------------------------------------------------------

RESULTS=""
STARTED_AT=$SECONDS

summary() {
  echo ""
  echo "============================================================"
  printf '%s' "$RESULTS"
  echo "============================================================"
  echo "total: $((SECONDS - STARTED_AT))s"
}

record() { RESULTS="${RESULTS}  $1  $2 ($3s)
"; }

run_step() {
  name="$1"; shift
  echo ""
  echo "==> ${name}"
  t0=$SECONDS
  if "$@"; then
    record "PASS" "$name" "$((SECONDS - t0))"
  else
    record "FAIL" "$name" "$((SECONDS - t0))"
    summary
    echo ""
    echo "local-ci-macos: FAILED at '${name}'." >&2
    exit 1
  fi
}

# --- The checks, in ios-ci.yml's order -------------------------------------

# 1. JesseKit local package: JesseCore + JesseNetworking + JesseConversations.
#    First because it is by far the fastest feedback (seconds, no simulator) and
#    it is where most of the shared logic lives. Warnings-as-errors, symmetric
#    with the app build below.
jessekit() {
  ( cd "$ROOT/JesseKit" \
    && swift build -Xswiftc -warnings-as-errors \
    && swift test -Xswiftc -warnings-as-errors )
}

# Simulator resolution mirrors the workflow's jq query exactly: newest available
# runtime for the platform, and a device type that runtime itself declares it
# supports. The one deliberate difference from CI is REUSE — CI creates a throwaway
# device per run because its runner is throwaway; creating a new simulator on every
# push here would leak devices and re-pay first-boot cost each time.
resolve_sim() {
  platform="$1"; family="$2"; sim_name="$3"

  read -r RUNTIME_ID RUNTIME_VER DEVTYPE DEV_NAME < <(
    xcrun simctl list runtimes --json | jq -r \
      --arg platform "$platform" --arg family "$family" '
      .runtimes
      | map(select(.platform == $platform and .isAvailable))
      | map({
          id: .identifier,
          ver: .version,
          dt: (.supportedDeviceTypes | map(select(.productFamily == $family)) | last)
        })
      | map(select(.dt != null))
      | sort_by(.ver | split(".") | map(tonumber))
      | last
      | "\(.id) \(.ver) \(.dt.identifier) \(.dt.name)"
    '
  )
  if [ -z "${RUNTIME_ID:-}" ] || [ "$RUNTIME_ID" = "null" ] || [ -z "${DEVTYPE:-}" ]; then
    echo "No available ${platform} runtime with a ${family} device type." >&2
    echo "  Install one via Xcode > Settings > Components." >&2
    return 1
  fi

  UDID="$(
    xcrun simctl list devices --json \
      | jq -r --arg rt "$RUNTIME_ID" --arg n "$sim_name" \
        '(.devices[$rt] // []) | map(select(.name == $n and .isAvailable)) | last | .udid // empty'
  )"
  if [ -z "$UDID" ]; then
    UDID="$(xcrun simctl create "$sim_name" "$DEVTYPE" "$RUNTIME_ID")"
  fi
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

  SIM_DEST="platform=${platform} Simulator,id=${UDID}"
  SIM_VER="$RUNTIME_VER"
  echo "Resolved: ${DEV_NAME} (${platform} ${RUNTIME_VER}) -> ${SIM_DEST}"
}

resolve_ios_sim() {
  resolve_sim "iOS" "iPhone" "jesse-local-ci-iphone" || return 1
  IOS_DEST="$SIM_DEST"; IOS_TARGET="$SIM_VER"
}

resolve_watch_sim() {
  resolve_sim "watchOS" "Apple Watch" "jesse-local-ci-watch" || return 1
  WATCH_DEST="$SIM_DEST"
}

# `xcodebuild test` REFUSES to write a -resultBundlePath that already exists
# ("error: Existing file at -resultBundlePath"), so the second local run of this
# script would fail before compiling a line. CI never meets this because its
# runner is empty every time; a developer Mac meets it every time but the first.
# Clearing the bundle (and only the bundle — DerivedData is kept, and reusing it
# is the whole reason a local run is fast) is what makes this re-runnable.
fresh_bundle() { rm -rf "$ROOT/Jesse/build/$1"; }

# `xcodebuild test` deliberately does NOT carry SWIFT_TREAT_WARNINGS_AS_ERRORS,
# and that asymmetry is CI's, reproduced here on purpose rather than tidied up:
# the test action also builds JesseUITests, whose XCUIApplication calls emit
# MainActor-isolation warnings in Swift 5 mode. Promoting those to errors fails
# the run on code you did not touch. Warnings are errors for SHIPPING code (the
# `build` action) only.
ios_build() {
  ( cd "$ROOT/Jesse" && xcodebuild build \
      -scheme Jesse \
      -destination "$IOS_DEST" \
      -derivedDataPath build/DerivedData \
      IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
      SWIFT_SUPPRESS_WARNINGS=NO \
      CODE_SIGNING_ALLOWED=NO )
}

# CODE_SIGNING_ALLOWED=NO is not an optimization, it is fidelity: a bare local
# `xcodebuild test` builds SIGNED and diverges from CI. Code that reads its
# identity from entitlements (HealthKit's HKSource.default() is the one that bit
# this repo) passes signed and takes the test host down unsigned.
ios_test() {
  fresh_bundle Result.xcresult
  ( cd "$ROOT/Jesse" && xcodebuild test \
      -scheme Jesse \
      -destination "$IOS_DEST" \
      -derivedDataPath build/DerivedData \
      -resultBundlePath build/Result.xcresult \
      -enableCodeCoverage YES \
      IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" \
      CODE_SIGNING_ALLOWED=NO )
}

watch_build() {
  ( cd "$ROOT/Jesse" && xcodebuild build \
      -scheme "Jesse Watch App" \
      -destination "$WATCH_DEST" \
      -derivedDataPath build/DerivedDataWatch \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
      SWIFT_SUPPRESS_WARNINGS=NO \
      CODE_SIGNING_ALLOWED=NO )
}

watch_test() {
  fresh_bundle ResultWatch.xcresult
  ( cd "$ROOT/Jesse" && xcodebuild test \
      -scheme "Jesse Watch App" \
      -destination "$WATCH_DEST" \
      -derivedDataPath build/DerivedDataWatch \
      -resultBundlePath build/ResultWatch.xcresult \
      CODE_SIGNING_ALLOWED=NO )
}

mac_build() {
  ( cd "$ROOT/Jesse" && xcodebuild build \
      -scheme "Jesse Mac" \
      -destination "platform=macOS" \
      -derivedDataPath build/DerivedDataMac \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
      SWIFT_SUPPRESS_WARNINGS=NO \
      CODE_SIGNING_ALLOWED=NO )
}

mac_test() {
  fresh_bundle ResultMac.xcresult
  ( cd "$ROOT/Jesse" && xcodebuild test \
      -scheme "Jesse Mac" \
      -destination "platform=macOS" \
      -derivedDataPath build/DerivedDataMac \
      -resultBundlePath build/ResultMac.xcresult \
      CODE_SIGNING_ALLOWED=NO )
}

# CI's "Report test count" steps are a real gate, not decoration: a suite that
# silently ran ZERO tests is the failure mode a green xcodebuild does not catch.
# Same assertion here.
report_counts() {
  rc=0
  for pair in "JesseTests:Result.xcresult" "JesseWatchTests:ResultWatch.xcresult" "JesseMacTests:ResultMac.xcresult"; do
    label="${pair%%:*}"; bundle="$ROOT/Jesse/build/${pair#*:}"
    if [ ! -d "$bundle" ]; then
      echo "No result bundle at ${bundle}" >&2
      rc=1
      continue
    fi
    s="$(xcrun xcresulttool get test-results summary --path "$bundle")"
    total=$(printf '%s' "$s" | jq -r '.totalTestCount')
    passed=$(printf '%s' "$s" | jq -r '.passedTests')
    failed=$(printf '%s' "$s" | jq -r '.failedTests')
    skipped=$(printf '%s' "$s" | jq -r '.skippedTests')
    echo "${label}: total=${total} passed=${passed} failed=${failed} skipped=${skipped}"
    if [ "${total}" -le 0 ]; then
      echo "Expected ${label} to run at least one test, got ${total}" >&2
      rc=1
    fi
  done
  return $rc
}

run_step "JesseKit package (build + test, warnings-as-errors)" jessekit
run_step "Resolve iOS simulator"                               resolve_ios_sim
run_step "iOS build (warnings-as-errors)"                      ios_build
run_step "iOS test"                                            ios_test
run_step "Resolve watchOS simulator"                           resolve_watch_sim
run_step "watch build (warnings-as-errors)"                    watch_build
run_step "watch test"                                          watch_test
run_step "Mac build (warnings-as-errors)"                      mac_build
run_step "Mac test"                                            mac_test
run_step "Test counts (all three suites ran)"                  report_counts

summary
echo ""
echo "local-ci-macos: ALL CHECKS PASSED — this is what the nightly would run."
