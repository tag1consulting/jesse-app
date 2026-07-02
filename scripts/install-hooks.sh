#!/usr/bin/env bash
#
# install-hooks.sh — wire this repo's tracked git hooks into your clone. Points
# git at scripts/hooks (tracked, so a fresh clone gets the same gate) rather than
# copying into .git/hooks. Run once after cloning:
#
#     scripts/install-hooks.sh
#
# The pre-push hook then blocks any push that changes a component without bumping
# its version + CHANGELOG (see scripts/version-guard.sh / bridge/README.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git config core.hooksPath scripts/hooks
chmod +x scripts/hooks/* 2>/dev/null || true

echo "Installed git hooks: core.hooksPath = scripts/hooks"
echo "Pre-push version enforcement is now active."
