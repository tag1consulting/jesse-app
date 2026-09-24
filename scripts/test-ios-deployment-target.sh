#!/usr/bin/env bash
#
# test-ios-deployment-target.sh — exercise scripts/ios-deployment-target.sh.
#
# The rule it guards is one line of arithmetic with two ways to get it silently
# wrong: compare versions as strings (26.10 sorts below 26.5) or pick the higher
# of the pair (which is the bug this helper exists to fix, and which looks fine
# until an SDK deprecates something). Both are pinned below, against fixture
# project files written to a temp directory, plus one case against the REAL
# pbxproj so a future change to the shipped target is noticed here.
#
# No simulator, no Xcode, no macOS: CI runs this on Linux on every push.
#
# Usage: bash scripts/test-ios-deployment-target.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/ios-deployment-target.sh"
REAL_PBXPROJ="$ROOT/Jesse/Jesse.xcodeproj/project.pbxproj"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASSED=0
FAILED=0

# Writes a fixture pbxproj whose IPHONEOS_DEPLOYMENT_TARGET entries are exactly
# the arguments given, wrapped in enough surrounding noise that the helper has to
# actually match the setting rather than the whole line.
fixture() {
  name="$1"; shift
  path="$TMPDIR_TEST/$name.pbxproj"
  {
    echo '/* Begin XCBuildConfiguration section */'
    for target in "$@"; do
      echo '		B0D0 /* Debug */ = {'
      echo '			isa = XCBuildConfiguration;'
      echo '			buildSettings = {'
      echo '				CODE_SIGNING_ALLOWED = NO;'
      echo "				IPHONEOS_DEPLOYMENT_TARGET = ${target};"
      echo '				SWIFT_VERSION = 5.0;'
      echo '			};'
      echo '		};'
    done
    echo '/* End XCBuildConfiguration section */'
  } > "$path"
  echo "$path"
}

expect_output() {
  label="$1"; want="$2"; shift 2
  if got="$(bash "$HELPER" "$@" 2>/dev/null)"; then
    if [ "$got" = "$want" ]; then
      echo "  ok    ${label} -> ${got}"
      PASSED=$((PASSED + 1))
      return
    fi
    echo "  FAIL  ${label}: expected '${want}', got '${got}'" >&2
  else
    echo "  FAIL  ${label}: expected '${want}', helper exited non-zero" >&2
  fi
  FAILED=$((FAILED + 1))
}

expect_failure() {
  label="$1"; shift
  if out="$(bash "$HELPER" "$@" 2>&1)"; then
    echo "  FAIL  ${label}: expected a non-zero exit, got success printing '${out}'" >&2
    FAILED=$((FAILED + 1))
    return
  fi
  echo "  ok    ${label} (rejected)"
  PASSED=$((PASSED + 1))
}

echo "test-ios-deployment-target: $HELPER"

PROJ_265="$(fixture proj265 26.5 26.5 26.5)"

# A newer simulator must NOT drag the build forward: this is the whole point.
expect_output "runtime 27.0, project 26.5"   "26.5"  27.0   "$PROJ_265"
# An older simulator must drag it back, or the app cannot install.
expect_output "runtime 26.2, project 26.5"   "26.2"  26.2   "$PROJ_265"
# Equal is equal.
expect_output "runtime 26.5, project 26.5"   "26.5"  26.5   "$PROJ_265"
# Version order, not string order: as text "26.10" < "26.5", so a string compare
# would answer 26.10 here and quietly build against a newer SDK level.
expect_output "runtime 26.10, project 26.5"  "26.5"  26.10  "$PROJ_265"
# The same trap on the other side of the min.
expect_output "runtime 26.5, project 26.10"  "26.5"  26.5   "$(fixture proj2610 26.10)"

# A project that cannot say what it ships is an error, never a guess.
expect_failure "disagreeing targets"  26.5  "$(fixture mixed 26.5 26.5 18.0)"
expect_failure "no targets"           26.5  "$(fixture none)"
expect_failure "missing project file" 26.5  "$TMPDIR_TEST/does-not-exist.pbxproj"
expect_failure "non-numeric runtime"  "twenty-six"  "$PROJ_265"
expect_failure "no arguments"

# --project-target reports what the project declares, with no runtime in play,
# and is held to the same validation.
expect_output  "--project-target, fixture"      "26.5"  --project-target "$PROJ_265"
expect_output  "--project-target, real pbxproj" "26.5"  --project-target
expect_failure "--project-target, disagreeing"  --project-target "$(fixture mixed2 26.5 18.0)"

# And the real thing: the app ships 26.5, and the iOS 27 simulator must not move it.
expect_output "real pbxproj, runtime 27.0" "26.5" 27.0 "$REAL_PBXPROJ"
# Default path argument resolves to that same real project file.
expect_output "real pbxproj via default path" "26.5" 27.0

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "test-ios-deployment-target: ${PASSED} passed, ${FAILED} FAILED" >&2
  exit 1
fi
echo "test-ios-deployment-target: ${PASSED} passed"
