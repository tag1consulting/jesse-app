#!/usr/bin/env bash
#
# ci-guards.sh — cheap source-level guards against security regressions in the
# bridge. These are pattern checks, not a substitute for the test suite; they
# exist so a careless edit that reopens a closed finding fails CI loudly.
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/bridge/src"

fail=0
flag() {
  # $1 = human description, remaining args = matching lines
  echo "GUARD FAILED: $1"
  shift
  printf '  %s\n' "$@"
  fail=1
}

# Collect the bridge's Rust sources (portable to bash 3.2 — no mapfile).
RS=()
while IFS= read -r f; do
  RS+=("$f")
done < <(find "$SRC" -name '*.rs' -type f | sort)
if [ "${#RS[@]}" -eq 0 ]; then
  echo "ci-guards: no Rust sources found under $SRC" >&2
  exit 1
fi

# 1) acceptEdits (auto-accept permission mode) must never appear unless an
#    explicit --allowedTools list is also present in the same source. The agent
#    must run under a tool allowlist, never blanket auto-accept.
if grep -qn 'acceptEdits' "${RS[@]}"; then
  if ! grep -qn -- '--allowedTools' "${RS[@]}"; then
    flag "acceptEdits present without an --allowedTools allowlist" \
      "$(grep -n 'acceptEdits' "${RS[@]}")"
  fi
fi

# 2) The bearer token must not be compared with raw ==/!= (timing-unsafe and a
#    sign the auth path was hand-rolled around the intended check_auth helper).
if hits="$(grep -nE '(token[[:alnum:]_]*[[:space:]]*(==|!=))|((==|!=)[[:space:]]*[[:alnum:]_.]*token)' "${RS[@]}" || true)"; then
  if [ -n "$hits" ]; then
    flag "raw ==/!= comparison involving a token" "$hits"
  fi
fi

# 3) No literal 0.0.0.0 wildcard as a default bind (would expose the bridge on
#    every interface). Matches it only in a default-value context, so test
#    fixtures that pass "0.0.0.0" as input are not flagged.
if hits="$(grep -nE 'unwrap_or(_else)?\([^)]*0\.0\.0\.0|bind:[[:space:]]*"0\.0\.0\.0"' "${RS[@]}" || true)"; then
  if [ -n "$hits" ]; then
    flag "literal 0.0.0.0 used as a default bind address" "$hits"
  fi
fi

# 4) The token must never be written to a world-readable temp path.
if hits="$(grep -nE '/tmp/[^"'"'"']*token|jesse_token' "${RS[@]}" || true)"; then
  if [ -n "$hits" ]; then
    flag "token written to a /tmp path" "$hits"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "ci-guards: one or more guards failed." >&2
  exit 1
fi
echo "ci-guards: all guards passed."
