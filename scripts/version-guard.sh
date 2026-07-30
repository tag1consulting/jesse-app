#!/usr/bin/env bash
#
# version-guard.sh — make version increments mandatory and enforced.
#
# The bridge (Rust) and the iOS app are versioned independently. This guard fails
# a commit that changes a component's sources without bumping that component's
# version and updating CHANGELOG.md:
#
#   * Any real change under bridge/ (anything but a pure Cargo.toml version-line
#     change) requires bridge/Cargo.toml's `version` to be a valid SemVer INCREASE
#     over the diff base.
#   * Any change under Jesse/ requires MARKETING_VERSION or CURRENT_PROJECT_VERSION
#     in the app's project.pbxproj to have INCREASED.
#   * Whenever either component is bumped, CHANGELOG.md must change in the same
#     commit.
#
# Diff base is overridable via VERSION_GUARD_BASE (default HEAD~1) so it's testable
# and reusable by the pre-push hook (which passes the upstream range's base). On
# the initial commit / a shallow checkout with no such base, it SKIPS cleanly.
#
# bash-3.2 portable (no mapfile / associative arrays); version lines are parsed
# with grep/sed only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
flag() { echo "VERSION GUARD FAILED: $1" >&2; fail=1; }

# --- Base resolution. This used to be `HEAD~1` with a clean skip when that commit
#     was absent, and the consequence was that this guard NEVER RAN IN CI: the
#     workflow checks out at depth 1, so `HEAD~1` is not in the repository and every
#     single run logged "no diff base — skipping" and then "all guards passed". A
#     guard that reports success for a check it did not perform is worse than no
#     guard, so the skip is gone and the base is derived from the integration branch
#     instead.
#
#     `HEAD~1` was also the wrong question. What the rule means is "compared with
#     what is on main", which for a feature branch of any length is the MERGE BASE,
#     not the previous commit — otherwise only the last commit of a branch is
#     checked. The needed history is why CI must check out with `fetch-depth: 0`.
UPSTREAM="${VERSION_GUARD_UPSTREAM:-origin/main}"

if [ -n "${VERSION_GUARD_BASE:-}" ]; then
  # An explicit base (the pre-push hook passes the upstream range's base; a human
  # passes `main`). Honour it, but never trust it blindly: a base that is BEHIND the
  # upstream measures the wrong range and can report a pass for versions that were
  # already bumped by someone else's merge. That is not hypothetical — a local `main`
  # left stale by days of merges elsewhere produced exactly that false pass.
  BASE="$VERSION_GUARD_BASE"
  if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
    flag "VERSION_GUARD_BASE=${BASE} is not a commit in this repository."
    echo "version-guard: enforcement failed (bad explicit base)." >&2
    exit 1
  fi
  if git rev-parse --verify --quiet "${UPSTREAM}^{commit}" >/dev/null 2>&1 \
     && ! git merge-base --is-ancestor "$UPSTREAM" "$BASE"; then
    behind="$(git rev-list --count "${BASE}..${UPSTREAM}")"
    flag "VERSION_GUARD_BASE=${BASE} is ${behind} commit(s) behind ${UPSTREAM} — the
  comparison would measure the wrong range. Run 'git fetch origin' and use
  ${UPSTREAM} (or omit VERSION_GUARD_BASE entirely and let it resolve)."
    echo "version-guard: enforcement failed (stale explicit base)." >&2
    exit 1
  fi
else
  # The upstream ref may be absent in a fresh CI checkout. Try ONCE to fetch it
  # before giving up, so the guard does not depend on how the workflow happens to be
  # configured — `fetch-depth: 0` makes this a no-op, and this makes a future
  # regression of that setting non-fatal.
  if ! git rev-parse --verify --quiet "${UPSTREAM}^{commit}" >/dev/null 2>&1; then
    case "$UPSTREAM" in
      */*) git fetch --quiet --no-tags "${UPSTREAM%%/*}" "${UPSTREAM#*/}" 2>/dev/null || true ;;
    esac
  fi
fi

if [ -z "${BASE:-}" ]; then
  if ! git rev-parse --verify --quiet "${UPSTREAM}^{commit}" >/dev/null 2>&1; then
    if [ "$(git rev-list --count HEAD)" = "1" ]; then
      # The genuine initial commit: nothing to compare against, and saying so
      # distinctly matters — this is the ONLY remaining skip.
      echo "version-guard: initial commit (no parent) — nothing to compare."
      exit 0
    fi
    flag "cannot resolve a diff base: ${UPSTREAM} is missing, and fetching it failed.
  In CI this means the checkout has no history — set 'fetch-depth: 0' on
  actions/checkout. Locally, run 'git fetch origin'. Refusing to pass vacuously."
    echo "version-guard: enforcement failed (no resolvable base)." >&2
    exit 1
  fi
  if [ "$(git rev-parse "$UPSTREAM")" = "$(git rev-parse HEAD)" ]; then
    # We ARE the integration branch (a push to main, or a local main). The merge base
    # with ourselves is HEAD, which would compare a commit against itself and pass
    # vacuously — the very shape being removed here. The meaningful base is the
    # previous commit on the branch.
    if ! BASE="$(git rev-parse --verify --quiet HEAD~1)"; then
      echo "version-guard: initial commit (no parent) — nothing to compare."
      exit 0
    fi
  else
    BASE="$(git merge-base "$UPSTREAM" HEAD)"
  fi
fi

# Self-check the resolved base before trusting any comparison against it, in the
# spirit of ci-guards.sh's matcher self-check: a base that is not an ancestor of HEAD
# makes every `git diff BASE HEAD` below meaningless.
if ! git merge-base --is-ancestor "$BASE" HEAD; then
  flag "resolved base $(git rev-parse --short "$BASE") is not an ancestor of HEAD —
  the diffs below would not describe this branch's own changes."
  echo "version-guard: enforcement failed (base is not an ancestor)." >&2
  exit 1
fi
echo "version-guard: base $(git rev-parse --short "$BASE") (from ${VERSION_GUARD_BASE:+VERSION_GUARD_BASE=$VERSION_GUARD_BASE}${VERSION_GUARD_BASE:-merge-base with $UPSTREAM})."

changed_under() {
  # Files changed between BASE and HEAD under a given pathspec (may be empty).
  git diff --name-only "$BASE" HEAD -- "$1"
}

# --- SemVer compare (numeric major.minor.patch; pre-release/build metadata is
#     stripped before comparing). Returns 0 iff $1 is strictly greater than $2,
#     2 if either operand isn't a clean numeric triple.
semver_gt() {
  v1="${1%%[-+]*}"; v2="${2%%[-+]*}"
  M1="${v1%%.*}"; r1="${v1#*.}"; m1="${r1%%.*}"; p1="${r1#*.}"
  M2="${v2%%.*}"; r2="${v2#*.}"; m2="${r2%%.*}"; p2="${r2#*.}"
  for n in "$M1" "$m1" "$p1" "$M2" "$m2" "$p2"; do
    case "$n" in ''|*[!0-9]*) return 2;; esac
  done
  if [ "$M1" -ne "$M2" ]; then [ "$M1" -gt "$M2" ]; return; fi
  if [ "$m1" -ne "$m2" ]; then [ "$m1" -gt "$m2" ]; return; fi
  [ "$p1" -gt "$p2" ]
}

# ---- Bridge --------------------------------------------------------------

# The package version line at a ref (anchored ^version = so dependency lines like
# `reqwest = { version = "0.12" }` never match).
bridge_version_at() {
  git show "$1:bridge/Cargo.toml" 2>/dev/null \
    | grep -E '^version = ' | head -1 \
    | sed -E 's/^version = "([^"]+)".*/\1/'
}

bridge_bumped=0
bridge_changes="$(changed_under bridge/ || true)"
if [ -n "$bridge_changes" ]; then
  # A "real" change = anything under bridge/ other than a pure Cargo.toml
  # version-line change (that lone case IS the bump, and needs no further bump).
  real=0
  if echo "$bridge_changes" | grep -qv '^bridge/Cargo\.toml$'; then
    real=1   # some file other than Cargo.toml changed
  else
    # Only Cargo.toml changed — is any non-version line in its diff?
    if git diff "$BASE" HEAD -- bridge/Cargo.toml \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
        | grep -qvE '^[+-]version = '; then
      real=1
    fi
  fi

  if [ "$real" -eq 1 ]; then
    old="$(bridge_version_at "$BASE")"
    new="$(bridge_version_at HEAD)"
    if [ -z "$new" ]; then
      flag "could not read version from bridge/Cargo.toml at HEAD."
    elif [ "$old" = "$new" ]; then
      flag "bridge/ changed but bridge/Cargo.toml version is still \"$new\". Bump it (patch/minor/major by change type) and add a CHANGELOG entry."
    elif semver_gt "$new" "$old"; then
      bridge_bumped=1
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        flag "bridge version \"$old\" -> \"$new\" is not a clean SemVer triple."
      else
        flag "bridge version must INCREASE: \"$old\" -> \"$new\" is not an increase."
      fi
    fi
  fi
fi

# ---- App -----------------------------------------------------------------

PBXPROJ="$(git ls-files 'Jesse/*.xcodeproj/project.pbxproj' | head -1)"

app_field_at() {
  # $1 = ref, $2 = field name (MARKETING_VERSION | CURRENT_PROJECT_VERSION)
  git show "$1:$PBXPROJ" 2>/dev/null \
    | grep -E "[[:space:]]$2 = " | head -1 \
    | sed -E "s/.*$2 = ([^;]+);.*/\1/"
}

app_bumped=0
app_changes="$(changed_under Jesse/ || true)"
if [ -n "$app_changes" ]; then
  if [ -z "$PBXPROJ" ]; then
    flag "Jesse/ changed but no project.pbxproj was found to read the version from."
  else
    mk_old="$(app_field_at "$BASE" MARKETING_VERSION)"
    mk_new="$(app_field_at HEAD MARKETING_VERSION)"
    bn_old="$(app_field_at "$BASE" CURRENT_PROJECT_VERSION)"
    bn_new="$(app_field_at HEAD CURRENT_PROJECT_VERSION)"

    increased=0
    # Build number: integer increase (only when both sides are clean integers).
    if [ -n "$bn_old" ] && [ -n "$bn_new" ] \
       && [ -z "$(printf '%s' "$bn_old$bn_new" | tr -d '0-9')" ]; then
      if [ "$bn_new" -gt "$bn_old" ]; then increased=1; fi
    fi
    # Marketing version: SemVer-ish increase (handles "1.0" as 1.0.0).
    if [ "$increased" -eq 0 ] && [ -n "$mk_old" ] && [ -n "$mk_new" ]; then
      if semver_gt "$mk_new" "$mk_old"; then increased=1; fi
    fi

    if [ "$increased" -eq 1 ]; then
      app_bumped=1
    else
      flag "Jesse/ changed but the app version did not increase (MARKETING_VERSION \"$mk_old\" -> \"$mk_new\", CURRENT_PROJECT_VERSION \"$bn_old\" -> \"$bn_new\"). Bump CURRENT_PROJECT_VERSION (build) or MARKETING_VERSION in $PBXPROJ and add a CHANGELOG entry."
    fi
  fi
fi

# ---- CHANGELOG -----------------------------------------------------------

if [ "$bridge_bumped" -eq 1 ] || [ "$app_bumped" -eq 1 ]; then
  if [ -z "$(changed_under CHANGELOG.md || true)" ]; then
    flag "a component was bumped but CHANGELOG.md was not updated in the same commit. Add an entry for the new version."
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "version-guard: enforcement failed (base=$BASE)." >&2
  exit 1
fi
echo "version-guard: OK (base=$BASE; bridge_bumped=$bridge_bumped app_bumped=$app_bumped)."
