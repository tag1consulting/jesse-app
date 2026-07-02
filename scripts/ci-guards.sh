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
#    Covers both the `*token* ==/!=` form and the actual H1 shape where the
#    secret was compared via locals (`got`/`expected`/the authorization header).
if hits="$(grep -nE '(token[[:alnum:]_]*[[:space:]]*(==|!=))|((==|!=)[[:space:]]*[[:alnum:]_.]*token)|((got|expected|presented|authorization)[[:alnum:]_]*[[:space:]]*(==|!=))|((==|!=)[[:space:]]*(got|expected|presented|authorization))' "${RS[@]}" || true)"; then
  if [ -n "$hits" ]; then
    flag "raw ==/!= comparison involving a token or auth-header value" "$hits"
  fi
fi

# 2b) Positively assert the auth path actually uses a constant-time primitive.
#     Guard #2 catching the unsafe form is necessary but not sufficient — a
#     vacuous pass (no compare at all, or a refactor that drops the check)
#     would slip through. Require ct_eq / constant_time_eq to be present in the
#     same file that DEFINES check_auth.
#
#     Match the definition (`fn check_auth(` — open paren right after the name),
#     not the substring `fn check_auth`: after the module split the auth unit
#     tests live in the same tree and their names (`fn check_auth_wrong_token…`)
#     would otherwise make this resolve to several files. Each defining file
#     (there should be exactly one) is checked independently, so the guard is
#     robust to any file layout without being weakened.
AUTH_FILES="$(grep -lE 'fn check_auth\(' "${RS[@]}" || true)"
if [ -z "$AUTH_FILES" ]; then
  flag "check_auth function not found in bridge sources" "expected an fn check_auth("
else
  while IFS= read -r auth_file; do
    [ -n "$auth_file" ] || continue
    if ! grep -qE 'ct_eq|constant_time_eq' "$auth_file"; then
      flag "check_auth's file does not use a constant-time compare (ct_eq/constant_time_eq)" \
        "$auth_file"
    fi
  done <<< "$AUTH_FILES"
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

# 5) (R5/T9) No personal infrastructure in tracked files — a real tailnet IP,
#    MagicDNS/tailnet id, a developer's machine name, or a personal absolute
#    home path must never ship. Scans the whole tracked tree (STATUS.md and
#    other internal worklogs are .gitignored, so they are out of scope here).
PERSONAL='100\.70\.149\.25|tailnet|build-host|/Users/user'
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Exclude this script: it is the one reviewed place those patterns must appear
  # (as the matcher itself), so it would otherwise flag its own definition.
  if hits="$(git -C "$ROOT" ls-files -z -- . ':!:scripts/ci-guards.sh' \
      | xargs -0 grep -nE "$PERSONAL" 2>/dev/null || true)"; then
    if [ -n "$hits" ]; then
      flag "personal infra (tailnet IP / MagicDNS / machine name / home path) in a tracked file" "$hits"
    fi
  fi
fi

# 6) (R5/T9) Run a secret scanner over the tree when one is available. gitleaks
#    is best-effort locally (skipped with a note if absent); CI installs it as a
#    required step so a leaked credential cannot merge.
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks detect --source "$ROOT" --no-banner --redact >/dev/null 2>&1; then
    flag "gitleaks reported potential secrets" \
      "$(gitleaks detect --source "$ROOT" --no-banner --redact 2>&1 | tail -20)"
  fi
else
  echo "ci-guards: gitleaks not installed — skipping secret scan locally (enforced in CI)." >&2
fi

# 7) (Versioning) Mandatory version bumps. A change to a component's sources must
#    bump that component's version and update CHANGELOG.md. Delegated to the
#    dedicated version-guard.sh (shared with the pre-push hook); it skips cleanly
#    when there's no parent commit (initial commit / shallow checkout).
if ! bash "$ROOT/scripts/version-guard.sh"; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "ci-guards: one or more guards failed." >&2
  exit 1
fi
echo "ci-guards: all guards passed."
