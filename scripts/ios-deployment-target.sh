#!/usr/bin/env bash
#
# ios-deployment-target.sh — decide which IPHONEOS_DEPLOYMENT_TARGET a gate run
# should compile the app at, given the iOS runtime it is about to run on.
#
# THE RULE: build at the target the product actually ships, and lower it only far
# enough to fit an older simulator.
#
# Both gates (scripts/local-ci-macos.sh and .github/workflows/ios-ci.yml) used to
# pin the deployment target to the simulator's own version. That has exactly one
# real motivation — a runtime OLDER than the project's target cannot install the
# app — and pinning upward buys nothing while doing real harm: every API the
# newer SDK deprecates becomes a build error under warnings-as-errors, failing
# the gate on a diagnostic the shipping app never sees. (Concretely: the iOS 27
# simulator deprecates BGTaskScheduler.submit, which is perfectly current at the
# 26.5 target this app ships.)
#
# So: min(project target, runtime version), compared as VERSIONS. String order is
# wrong here and quietly so — "26.10" < "26.5" as text, and picking 26.10 for a
# 26.5 project would reintroduce the whole bug on the first two-digit minor.
#
# Usage:
#     ios-deployment-target.sh <runtime-version> [pbxproj-path]
#     ios-deployment-target.sh --project-target [pbxproj-path]
#
# <runtime-version>  the simulator runtime, e.g. 27.0 (from `xcrun simctl`).
# [pbxproj-path]     defaults to Jesse/Jesse.xcodeproj/project.pbxproj, resolved
#                    against the repository root, not the caller's cwd.
#
# --project-target   print the project's own declared target and stop, without
#                    consulting any runtime. Exists so a caller can name both
#                    numbers in its log line ("project ships X, simulator runs Y")
#                    without re-implementing the parse or inventing a sentinel
#                    runtime to pass in. Same validation, same error messages.
#
# Prints one version to stdout. Exits non-zero, with the reason on stderr, if the
# project declares no IPHONEOS_DEPLOYMENT_TARGET or declares several that
# disagree — either means the caller's idea of "the shipped target" is fiction
# and silently guessing one would hide it.
#
# Covered by scripts/test-ios-deployment-target.sh, which CI runs on Linux.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: $(basename "$0") <runtime-version> [pbxproj-path]" >&2
  echo "       $(basename "$0") --project-target [pbxproj-path]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

RUNTIME_VER="$1"
PBXPROJ="${2:-$ROOT/Jesse/Jesse.xcodeproj/project.pbxproj}"

PROJECT_TARGET_ONLY=no
if [ "$RUNTIME_VER" = "--project-target" ]; then
  PROJECT_TARGET_ONLY=yes
else
  case "$RUNTIME_VER" in
    '' | *[!0-9.]* | .* | *. | *..*)
      echo "$(basename "$0"): '$RUNTIME_VER' is not a version number (expected e.g. 27.0)." >&2
      exit 2
      ;;
  esac
fi

if [ ! -f "$PBXPROJ" ]; then
  echo "$(basename "$0"): no project file at ${PBXPROJ}." >&2
  exit 1
fi

# Every declared value, deduplicated. `sort -u` (not `sort -V -u`) is deliberate:
# this set is being tested for DISAGREEMENT, and -V would happily collapse two
# spellings of the same version into one, which is the case worth reporting.
PROJECT_TARGETS="$(
  sed -n 's/.*IPHONEOS_DEPLOYMENT_TARGET = \([^;]*\);.*/\1/p' "$PBXPROJ" \
    | sed 's/[[:space:]"]//g' \
    | grep -v '^$' \
    | sort -u
)"

if [ -z "$PROJECT_TARGETS" ]; then
  echo "$(basename "$0"): ${PBXPROJ} declares no IPHONEOS_DEPLOYMENT_TARGET." >&2
  exit 1
fi

if [ "$(printf '%s\n' "$PROJECT_TARGETS" | wc -l | tr -d '[:space:]')" != "1" ]; then
  echo "$(basename "$0"): ${PBXPROJ} declares more than one IPHONEOS_DEPLOYMENT_TARGET:" >&2
  printf '  %s\n' $PROJECT_TARGETS >&2
  echo "  Make every build configuration agree before a gate can build at 'the shipped target'." >&2
  exit 1
fi

PROJECT_TARGET="$PROJECT_TARGETS"

if [ "$PROJECT_TARGET_ONLY" = "yes" ]; then
  printf '%s\n' "$PROJECT_TARGET"
  exit 0
fi

# min(project, runtime), as versions.
printf '%s\n%s\n' "$PROJECT_TARGET" "$RUNTIME_VER" | sort -V | head -1
