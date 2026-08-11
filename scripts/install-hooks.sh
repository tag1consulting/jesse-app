#!/usr/bin/env bash
#
# install-hooks.sh — wire this repo's tracked git hooks into your clone. Points
# git at scripts/hooks (tracked, so a fresh clone gets the same gate) rather than
# copying into .git/hooks. Run once after cloning:
#
#     scripts/install-hooks.sh
#
# The pre-push hook then blocks a push that:
#
#   * changes a component without bumping its version + CHANGELOG
#     (scripts/version-guard.sh — see bridge/README.md), or
#   * changes Jesse/ or JesseKit/ and fails scripts/local-ci-macos.sh.
#
# The second one matters more than it looks: the hosted macOS job no longer runs
# on pull requests (it bills at 10x Linux and was ~the entire Actions spend), so
# this hook IS the app's pre-merge gate. The nightly ios-ci.yml run is a backstop
# that reports up to a day late.
#
# Escape hatches: `git push --no-verify` skips everything; `JESSE_SKIP_MAC_CI=1`
# skips only the slow Swift suite and keeps the version guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git config core.hooksPath scripts/hooks
chmod +x scripts/hooks/* 2>/dev/null || true

echo "Installed git hooks: core.hooksPath = scripts/hooks"
echo "Pre-push version enforcement is now active."
echo "Pre-push macOS CI is active for pushes that touch Jesse/ or JesseKit/"
echo "  (scripts/local-ci-macos.sh; skip with JESSE_SKIP_MAC_CI=1)."
