#!/usr/bin/env bash
#
# install-sentinel.sh — render the sentinel's LaunchAgent and install its binary.
#
# THIS SCRIPT NEVER RUNS launchctl. It writes two files and prints the one command you run
# yourself, because bootstrapping a service that can restart every other service on the box
# is a decision a person makes, not a side effect of an install script.
#
# It also never writes a token into this repository. The rendered plist carries two bearer
# tokens and is written to ~/Library/LaunchAgents/ with mode 0600; the template in the repo
# carries only @@PLACEHOLDER@@.
#
# WHAT IT READS FROM THE BRIDGE'S PLIST. The sentinel needs several values that MUST agree
# with the bridge's — the bridge token, the child PATH, the APNs settings, the bind host —
# and retyping them is how they drift. So this script reads them out of the bridge's own
# LaunchAgent by default. Every one is overridable by an environment variable.
#
# BUILD IT FROM THE DEFAULT BRANCH FIRST. This installs whatever
# `bridge/target/release/jesse-sentinel` currently holds, and NOTHING downstream ever
# checks what that was built from: launchd runs it, and a deploy never replaces it — the
# sentinel is the process that PERFORMS a deploy, so it is deliberately absent from
# `bridge/deploy-bins.toml`. A checkout left on a feature branch therefore installs
# unreviewed ops code, and every line this script prints still says success.
#
#     git checkout main && git pull
#     (cd bridge && cargo build --release)
#     scripts/install-sentinel.sh
#
# The check below enforces that rather than trusting it. Override it deliberately with
# SENTINEL_ALLOW_ANY_REF=1, or aim it elsewhere with SENTINEL_REF=<branch>.
#
# Usage:
#     scripts/install-sentinel.sh                 # render + install, print the bootstrap line
#     SENTINEL_LABEL=com.example.jesse-sentinel \
#     SENTINEL_BIND=100.64.0.1 \
#     scripts/install-sentinel.sh
#     SENTINEL_ALLOW_ANY_REF=1 scripts/install-sentinel.sh   # a branch build, on purpose
#
# bash-3.2 portable: no associative arrays, no mapfile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/scripts/jesse-sentinel.plist.template"
BUILT="$ROOT/bridge/target/release/jesse-sentinel"

die() { echo "install-sentinel: $*" >&2; exit 1; }
note() { echo "install-sentinel: $*"; }

[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

# ---- Which ref this is being built from ----------------------------------------------
#
# The failsafe for the header's first instruction, because the cost of ignoring it is
# invisible: the wrong binary installs cleanly, launchd runs it, and no later step ever
# compares it against anything. This checks the CHECKOUT, which is a proxy for what
# `cargo build` last produced and not proof of it — so it also reports a binary older
# than HEAD further down rather than implying a freshness it cannot verify.
SENTINEL_REF="${SENTINEL_REF:-main}"
if [ "${SENTINEL_ALLOW_ANY_REF:-0}" = "1" ]; then
  note "SENTINEL_ALLOW_ANY_REF=1 — not checking which ref this was built from."
elif ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  note "WARNING: $ROOT is not a git checkout, so the ref could not be checked."
else
  # A detached HEAD reports the literal string "HEAD", which is not $SENTINEL_REF and so
  # fails here — which is correct, and the message names it.
  ref_now="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  [ "$ref_now" = "$SENTINEL_REF" ] || die "this checkout is on '$ref_now', not '$SENTINEL_REF'.
The sentinel is ops code that no deploy will ever replace, so it is installed from
'$SENTINEL_REF' only:
    git -C '$ROOT' checkout $SENTINEL_REF && git -C '$ROOT' pull
    (cd '$ROOT/bridge' && cargo build --release)
Set SENTINEL_ALLOW_ANY_REF=1 to install a '$ref_now' build on purpose."

  # A dirty tree means the binary corresponds to no commit at all, which is strictly
  # worse than the wrong branch: there is nothing to review and nothing to roll back to.
  [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null || true)" ] \
    || die "'$SENTINEL_REF' has uncommitted changes, so a build from it matches no commit.
Commit or stash them and rebuild, or set SENTINEL_ALLOW_ANY_REF=1 to install anyway."

  # Local refs only. This deliberately does NOT fetch: a script that reaches the network
  # to answer a question nobody asked is a surprise, so it reports what it can see and
  # says plainly that it did not look further.
  if git -C "$ROOT" rev-parse --verify --quiet "origin/$SENTINEL_REF^{commit}" >/dev/null 2>&1
  then
    behind="$(git -C "$ROOT" rev-list --count "HEAD..origin/$SENTINEL_REF" 2>/dev/null || echo 0)"
    [ "$behind" = "0" ] || note "WARNING: $behind commit(s) behind origin/$SENTINEL_REF \
(no fetch was performed — 'git pull' first if that is stale)."
  fi
fi

# ---- Where things go ---------------------------------------------------------------

# The sentinel's own launchd label. It is YOUR reverse-DNS namespace; the default is the
# project's, which works and is what `scripts/ci-guards.sh` permits in a tracked file.
SENTINEL_LABEL="${SENTINEL_LABEL:-com.tag1.jesse-sentinel}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST_OUT="$AGENTS_DIR/$SENTINEL_LABEL.plist"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
BIN_OUT="$BIN_DIR/jesse-sentinel"
LOG_OUT="${SENTINEL_LOG:-$HOME/Library/Logs/jesse-sentinel.log}"

# The BRIDGE's launchd label and plist — the file this script reads its defaults from, and
# the file the reload-env verb bootstraps.
LABEL_BRIDGE="${LABEL_BRIDGE:-}"
if [ -z "$LABEL_BRIDGE" ]; then
  # Exactly one `*.jesse-bridge.plist` in the agents dir is the unambiguous case; anything
  # else has to be named explicitly rather than guessed.
  found=""
  count=0
  for f in "$AGENTS_DIR"/*.jesse-bridge.plist; do
    [ -f "$f" ] || continue
    found="$f"; count=$((count + 1))
  done
  [ "$count" -eq 1 ] || die "could not identify the bridge's LaunchAgent in $AGENTS_DIR \
($count candidates). Set LABEL_BRIDGE=<its label>."
  LABEL_BRIDGE="$(basename "$found" .plist)"
fi
BRIDGE_PLIST="${BRIDGE_PLIST:-$AGENTS_DIR/$LABEL_BRIDGE.plist}"
[ -f "$BRIDGE_PLIST" ] || die "bridge plist not found: $BRIDGE_PLIST (set BRIDGE_PLIST)"

# ---- Values read out of the bridge's plist ------------------------------------------

# One EnvironmentVariables entry, or empty. `plutil -extract … raw` is on every supported
# macOS and handles both the XML and binary plist forms.
#
# The exit status is what decides, NOT the output: on a missing key path plutil prints its
# error message to STDOUT and exits 1, so the obvious `… 2>/dev/null || true` captures
# "Could not extract value, error: …" AS THE VALUE and writes that sentence into the plist as
# an APNs topic. Measured, not theorised — the first run of this script did exactly that.
plist_value() { # $1 = plist path, $2 = key path
  local out
  if out="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)"; then
    printf '%s' "$out"
  fi
}
bridge_env() { plist_value "$BRIDGE_PLIST" "EnvironmentVariables.$1"; }

BRIDGE_TOKEN="${JESSE_TOKEN:-$(bridge_env JESSE_TOKEN)}"
[ -n "$BRIDGE_TOKEN" ] || die "no JESSE_TOKEN in $BRIDGE_PLIST and none in the environment. \
The sentinel needs the bridge's token for its proxied reads and its two proxy verbs."

CHILD_PATH="${SENTINEL_CHILD_PATH:-$(bridge_env PATH)}"
[ -n "$CHILD_PATH" ] || die "no PATH in $BRIDGE_PLIST — set SENTINEL_CHILD_PATH to the \
bridge child's PATH, or the qmd probe tests a resolution no turn performs."

BRIDGE_BIND="$(bridge_env JESSE_BIND)"
BRIDGE_PORT="${BRIDGE_PORT:-$(bridge_env JESSE_PORT)}"
[ -n "$BRIDGE_PORT" ] || BRIDGE_PORT=8765
BRIDGE_URL="${SENTINEL_BRIDGE_URL:-http://${BRIDGE_BIND:-127.0.0.1}:$BRIDGE_PORT}"

VAULT="$(bridge_env JESSE_VAULT)"
# JESSE_VAULT points at the vault SUBDIRECTORY; the git repo is its parent.
VAULT_REPO="${SENTINEL_VAULT_REPO:-${VAULT%/*}}"
[ -n "$VAULT_REPO" ] || die "could not derive the vault repo — set SENTINEL_VAULT_REPO."

TZ_VALUE="${SENTINEL_TZ:-$(bridge_env TZ)}"
[ -n "$TZ_VALUE" ] || TZ_VALUE="UTC"

APNS_KEY_PATH="${JESSE_APNS_KEY_PATH:-$(bridge_env JESSE_APNS_KEY_PATH)}"
APNS_KEY_ID="${JESSE_APNS_KEY_ID:-$(bridge_env JESSE_APNS_KEY_ID)}"
APNS_TEAM_ID="${JESSE_APNS_TEAM_ID:-$(bridge_env JESSE_APNS_TEAM_ID)}"
APNS_TOPIC="${JESSE_APNS_TOPIC:-$(bridge_env JESSE_APNS_TOPIC)}"
APNS_ENV="${JESSE_APNS_ENV:-$(bridge_env JESSE_APNS_ENV)}"

# ---- The sentinel's own settings ------------------------------------------------------

# Bind: the bridge's interface by default, so the phone reaches both over the same tailnet
# address. Loopback or 100.64.0.0/10 only — the binary refuses anything else.
SENTINEL_BIND="${SENTINEL_BIND:-${BRIDGE_BIND:-127.0.0.1}}"
SENTINEL_PORT="${SENTINEL_PORT:-8766}"
STATE_DIR="${SENTINEL_STATE_DIR:-$HOME/.jesse-sentinel}"
BRIDGE_STATE_DIR="${SENTINEL_BRIDGE_STATE_DIR:-$HOME/.jesse-bridge}"
LEDGER="${SENTINEL_LEDGER:-$VAULT_REPO/vault/Inbox/scheduled-jobs-ledger.jsonl}"

# The autocommit job's log, from its own plist (that is where the answer lives).
LABEL_AUTOCOMMIT="${LABEL_AUTOCOMMIT:-${LABEL_BRIDGE%-bridge}-autocommit}"
AUTOCOMMIT_LOG="${SENTINEL_AUTOCOMMIT_LOG:-}"
if [ -z "$AUTOCOMMIT_LOG" ] && [ -f "$AGENTS_DIR/$LABEL_AUTOCOMMIT.plist" ]; then
  AUTOCOMMIT_LOG="$(plist_value "$AGENTS_DIR/$LABEL_AUTOCOMMIT.plist" StandardOutPath)"
fi

# The remaining three labels follow the same namespace as the bridge's unless named.
LABEL_LOCK_REAPER="${LABEL_LOCK_REAPER:-${LABEL_BRIDGE%-bridge}-lock-reaper}"
LABEL_QMD_UPDATE="${LABEL_QMD_UPDATE:-com.qmd.update}"
LABEL_MINISERVE="${LABEL_MINISERVE:-${LABEL_BRIDGE%-bridge}-miniserve-diet-dashboard}"

# ---- Remote deploy ---------------------------------------------------------------------

# The clone the deploy verb builds in. NEVER a checkout someone works in: every deploy leaves
# it on a detached head, and doing that to a working tree mid-edit is not a thing a background
# service does.
DEPLOY_CLONE="${SENTINEL_DEPLOY_CLONE:-$HOME/deploy/jesse-app}"
# Where the three symlinks live. The same directory this script installs jesse-sentinel into.
BIN_DIR_DEPLOY="${SENTINEL_BIN_DIR:-$BIN_DIR}"
BUILD_STORE="$BIN_DIR_DEPLOY/jesse-bridge.d"
DEPLOYS_DIR="$STATE_DIR/deploys"

# owner/repo, whose `bridge` CI job vouches for a commit. Derived from this repository's own
# `origin` so a fork does not silently check the upstream's CI.
GITHUB_REPO="${SENTINEL_GITHUB_REPO:-}"
if [ -z "$GITHUB_REPO" ]; then
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  # Both forms: git@host:owner/repo.git and https://host/owner/repo.git
  GITHUB_REPO="$(printf '%s' "$origin_url" | sed -e 's|^.*[:/]\([^/:]*/[^/]*\)$|\1|' -e 's|\.git$||')"
fi
[ -n "$GITHUB_REPO" ] || die "could not derive the GitHub repo from this checkout's origin — \
set SENTINEL_GITHUB_REPO=owner/repo."

# A FINE-GRAINED, READ-ONLY token (Actions: read, Contents: read). Reused from a previous
# install if this is a re-install, so it is typed once.
GITHUB_TOKEN="${JESSE_SENTINEL_GITHUB_TOKEN:-}"
if [ -z "$GITHUB_TOKEN" ] && [ -f "$PLIST_OUT" ]; then
  GITHUB_TOKEN="$(plist_value "$PLIST_OUT" EnvironmentVariables.JESSE_SENTINEL_GITHUB_TOKEN)"
fi

# cargo. Not on a launchd job's PATH, so it is pinned rather than resolved.
CARGO_BIN="${SENTINEL_CARGO_BIN:-$(command -v cargo || true)}"
[ -n "$CARGO_BIN" ] || CARGO_BIN="$HOME/.cargo/bin/cargo"

# The sentinel's own token. Generated if not supplied — and printed ONCE at the end, because
# it also has to go into the bridge's plist for the pairing QR to carry it.
GENERATED_TOKEN=0
SENTINEL_TOKEN="${JESSE_SENTINEL_TOKEN:-}"
if [ -z "$SENTINEL_TOKEN" ]; then
  # Reuse the one already installed, if this is a re-install: regenerating it would silently
  # unpair the phone.
  if [ -f "$PLIST_OUT" ]; then
    SENTINEL_TOKEN="$(plist_value "$PLIST_OUT" EnvironmentVariables.JESSE_SENTINEL_TOKEN)"
  fi
fi
if [ -z "$SENTINEL_TOKEN" ]; then
  SENTINEL_TOKEN="$(openssl rand -hex 24)"
  GENERATED_TOKEN=1
fi
[ "$SENTINEL_TOKEN" != "$BRIDGE_TOKEN" ] || die "JESSE_SENTINEL_TOKEN equals JESSE_TOKEN. \
They must be disjoint — a leak of either one would otherwise grant both."

# ---- The binary -----------------------------------------------------------------------

[ -x "$BUILT" ] || die "no built binary at $BUILT — run:
    cd '$ROOT/bridge' && cargo build --release"

# A binary that EXISTS is not a binary that is CURRENT, and this is the last moment
# anybody could notice. Not fatal: a deliberate install of an older build is legitimate,
# and mtime is evidence rather than proof. Said out loud, once, so it cannot pass unseen.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  head_epoch="$(git -C "$ROOT" log -1 --format=%ct HEAD 2>/dev/null || echo 0)"
  bin_epoch="$(stat -f %m "$BUILT" 2>/dev/null || echo 0)"
  if [ "$head_epoch" -gt 0 ] && [ "$bin_epoch" -gt 0 ] && [ "$bin_epoch" -lt "$head_epoch" ]; then
    note "WARNING: $BUILT is older than the commit checked out here, so it was built from
    something else. Rebuild with (cd '$ROOT/bridge' && cargo build --release) unless
    installing an older build is what you meant."
  fi
fi

mkdir -p "$BIN_DIR" "$AGENTS_DIR" "$STATE_DIR"
chmod 700 "$STATE_DIR"
# Copy to a temp name and rename, so a running sentinel is replaced atomically rather than
# having its text segment overwritten underneath it.
cp "$BUILT" "$BIN_OUT.new"
chmod 755 "$BIN_OUT.new"
mv "$BIN_OUT.new" "$BIN_OUT"
note "installed $BIN_OUT"

# ---- Render ----------------------------------------------------------------------------

# A previous plist is kept, stamped, rather than overwritten: it is the only copy of the
# environment the currently-loaded service was bootstrapped from.
if [ -f "$PLIST_OUT" ]; then
  backup="$PLIST_OUT.bak-$(date +%Y%m%d%H%M%S)"
  cp "$PLIST_OUT" "$backup"
  chmod 600 "$backup"
  note "backed up the previous plist to $backup"
fi

# Substitution by exact placeholder. Values are XML-escaped first — a token is hex, but a
# path or a topic is not guaranteed to be, and an unescaped `&` makes the plist unparseable.
xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

rendered="$(cat "$TEMPLATE")"
subst() { # $1 = placeholder name, $2 = raw value
  local escaped
  escaped="$(xml_escape "$2")"
  # `awk` rather than `sed`, so a value containing `/` or `&` needs no further quoting.
  rendered="$(printf '%s' "$rendered" | awk -v ph="@@$1@@" -v val="$escaped" \
    '{ i = index($0, ph); while (i > 0) { $0 = substr($0, 1, i-1) val substr($0, i+length(ph)); i = index($0, ph) } print }')"
}

subst LABEL              "$SENTINEL_LABEL"
subst BIN                "$BIN_OUT"
subst LOG                "$LOG_OUT"
subst PATH               "$CHILD_PATH"
subst TZ                 "$TZ_VALUE"
subst SENTINEL_TOKEN     "$SENTINEL_TOKEN"
subst BRIDGE_TOKEN       "$BRIDGE_TOKEN"
subst SENTINEL_BIND      "$SENTINEL_BIND"
subst SENTINEL_PORT      "$SENTINEL_PORT"
subst BRIDGE_URL         "$BRIDGE_URL"
subst STATE_DIR          "$STATE_DIR"
subst BRIDGE_STATE_DIR   "$BRIDGE_STATE_DIR"
subst VAULT_REPO         "$VAULT_REPO"
subst LEDGER             "$LEDGER"
subst AUTOCOMMIT_LOG     "$AUTOCOMMIT_LOG"
subst BRIDGE_PLIST       "$BRIDGE_PLIST"
subst CHILD_PATH         "$CHILD_PATH"
subst DEPLOY_CLONE       "$DEPLOY_CLONE"
subst BIN_DIR            "$BIN_DIR_DEPLOY"
subst GITHUB_TOKEN       "$GITHUB_TOKEN"
subst GITHUB_REPO        "$GITHUB_REPO"
subst CARGO_BIN          "$CARGO_BIN"
subst LABEL_BRIDGE       "$LABEL_BRIDGE"
subst LABEL_AUTOCOMMIT   "$LABEL_AUTOCOMMIT"
subst LABEL_LOCK_REAPER  "$LABEL_LOCK_REAPER"
subst LABEL_QMD_UPDATE   "$LABEL_QMD_UPDATE"
subst LABEL_MINISERVE    "$LABEL_MINISERVE"
subst APNS_KEY_PATH      "$APNS_KEY_PATH"
subst APNS_KEY_ID        "$APNS_KEY_ID"
subst APNS_TEAM_ID       "$APNS_TEAM_ID"
subst APNS_TOPIC         "$APNS_TOPIC"
subst APNS_ENV           "$APNS_ENV"

# A surviving placeholder means a value this script forgot to substitute, and installing it
# would produce a service configured with a literal marker. Refuse, and name the lines.
if leftover="$(printf '%s' "$rendered" | grep -nE '@@[A-Z_]+@@' | head -5)"; then
  [ -z "$leftover" ] || die "the rendered plist still contains an unsubstituted placeholder \
— refusing to install it:
$leftover"
fi

# 0600 BEFORE the content: the file carries two bearer tokens, and creating it world-readable
# for even an instant is a window nobody needs.
umask 077
printf '%s\n' "$rendered" > "$PLIST_OUT"
chmod 600 "$PLIST_OUT"
plutil -lint "$PLIST_OUT" >/dev/null || die "the rendered plist does not parse: $PLIST_OUT"
note "rendered $PLIST_OUT (mode 0600)"

# ---- Remote deploy: the clone, the build store, and the rollback record ------------------

mkdir -p "$BUILD_STORE" "$DEPLOYS_DIR"
chmod 700 "$DEPLOYS_DIR"

if [ ! -d "$DEPLOY_CLONE/.git" ]; then
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [ -n "$origin_url" ]; then
    mkdir -p "$(dirname "$DEPLOY_CLONE")"
    note "cloning $origin_url into $DEPLOY_CLONE (first install only)"
    git clone --quiet "$origin_url" "$DEPLOY_CLONE" \
      || die "could not clone $origin_url into $DEPLOY_CLONE. Create it by hand, or set \
SENTINEL_DEPLOY_CLONE to a clone that already exists."
  else
    note "WARNING: no origin remote in $ROOT, so no deploy clone was created. \
POST /sentinel/deploy will refuse until $DEPLOY_CLONE exists."
  fi
else
  note "deploy clone already present at $DEPLOY_CLONE"
fi

# THE ROLLBACK RECORD FOR THE FIRST DEPLOY. Before this feature the bridge's plist named a
# built binary directly; the first deploy replaces ~/.local/bin/<name> with a symlink, and
# `deploys/previous` is the only thing that says where to go back to. Written here ONLY if it
# does not already exist — overwriting it on a re-install would throw away the record of a
# deployment that is currently live.
PREVIOUS="$DEPLOYS_DIR/previous"
if [ -f "$PREVIOUS" ]; then
  note "keeping the existing rollback record $PREVIOUS"
else
  # The path the bridge's plist runs today: ProgramArguments[0].
  BRIDGE_PROGRAM="$(plist_value "$BRIDGE_PLIST" ProgramArguments.0)"
  if [ -n "$BRIDGE_PROGRAM" ] && [ -e "$BRIDGE_PROGRAM" ]; then
    BRIDGE_PROGRAM_DIR="$(cd "$(dirname "$BRIDGE_PROGRAM")" && pwd)"
    {
      printf '{\n'
      first=1
      for b in jesse-bridge jesse-hook jesse-build-mcp; do
        [ -e "$BRIDGE_PROGRAM_DIR/$b" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        printf '  "%s": "%s"' "$b" "$BRIDGE_PROGRAM_DIR/$b"
        first=0
      done
      printf '\n}\n'
    } > "$PREVIOUS"
    chmod 600 "$PREVIOUS"
    note "recorded the current binaries in $PREVIOUS (the first deploy's rollback target)"
  else
    note "WARNING: could not read ProgramArguments[0] from $BRIDGE_PLIST, so no rollback \
record was written. The FIRST deploy will have nothing to roll back to; every one after it \
will."
  fi
fi

# ---- What to do next --------------------------------------------------------------------

UID_NOW="$(id -u)"
cat <<EOF

Nothing has been loaded. Run this yourself:

    launchctl bootstrap gui/$UID_NOW "$PLIST_OUT"

(replacing an already-loaded one needs a bootout first:
    launchctl bootout gui/$UID_NOW/$SENTINEL_LABEL 2>/dev/null; \\
    launchctl bootstrap gui/$UID_NOW "$PLIST_OUT")

Then check it:

    curl -s -H "Authorization: Bearer \$JESSE_SENTINEL_TOKEN" \\
      http://$SENTINEL_BIND:$SENTINEL_PORT/sentinel/status | head -40

Services it will address:
    bridge       $LABEL_BRIDGE
    autocommit   $LABEL_AUTOCOMMIT
    lock-reaper  $LABEL_LOCK_REAPER
    qmd-update   $LABEL_QMD_UPDATE
    miniserve    $LABEL_MINISERVE

Remote deploy:
    clone        $DEPLOY_CLONE
    build store  $BUILD_STORE
    repo         $GITHUB_REPO
    cargo        $CARGO_BIN
    CI token     $([ -n "$GITHUB_TOKEN" ] && echo "set" || echo "NOT SET — POST /sentinel/deploy will refuse")
EOF

# ---- The one plist edit this script will not make for you -------------------------------

BRIDGE_PROGRAM_NOW="$(plist_value "$BRIDGE_PLIST" ProgramArguments.0)"
case "$BRIDGE_PROGRAM_NOW" in
  "$BIN_DIR_DEPLOY/jesse-bridge")
    note "the bridge plist already runs $BIN_DIR_DEPLOY/jesse-bridge — nothing to change"
    ;;
  *)
    cat <<EOF

THE BRIDGE PLIST STILL RUNS A BINARY PATH, NOT THE SYMLINK.

    now: ${BRIDGE_PROGRAM_NOW:-(could not read ProgramArguments.0)}
    needs to be: $BIN_DIR_DEPLOY/jesse-bridge

Until it does, a deploy will swap the symlink and restart a bridge that re-execs the OLD
binary — the version check will not match and every deploy will roll itself back.

This script does not edit the bridge's plist. Run these yourself:

    plutil -replace ProgramArguments.0 -string "$BIN_DIR_DEPLOY/jesse-bridge" "$BRIDGE_PLIST"

    launchctl bootout gui/$UID_NOW/$LABEL_BRIDGE
    launchctl bootstrap gui/$UID_NOW "$BRIDGE_PLIST"

(bootout + bootstrap, not kickstart: a plist change only takes effect on a fresh
service record.)
EOF
    ;;
esac

if [ "$GENERATED_TOKEN" -eq 1 ]; then
  cat <<EOF

A NEW SENTINEL TOKEN WAS GENERATED. It is in $PLIST_OUT and printed once here:

    $SENTINEL_TOKEN

For the phone to pair the sentinel from the bridge's QR, the BRIDGE's plist
($BRIDGE_PLIST) needs these two in its EnvironmentVariables:

    JESSE_SENTINEL_TOKEN = $SENTINEL_TOKEN
    JESSE_SENTINEL_PORT  = $SENTINEL_PORT

A plist environment change needs bootout + bootstrap, not kickstart:

    launchctl bootout gui/$UID_NOW/$LABEL_BRIDGE
    launchctl bootstrap gui/$UID_NOW "$BRIDGE_PLIST"
EOF
fi
