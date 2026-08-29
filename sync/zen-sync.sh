#!/usr/bin/env bash
# zen-sync — bidirectional reconciler between a git repo's zen-state.json
# and the local Zen browser profile. Git is the sync transport.
#
#   repo (zen-state.json)  <-git push/pull->  other machines
#        |  ^                                    |
#   apply|  |project                            apply|  |project
#        v  |                                    v  |
#      local Zen profile  ---------------------- local Zen profile
#
# 3-way merge per collection (spaces/tabs/folders/groups/containers):
#   base = last state this machine applied (local state file)
#   local = current browser projection
#   repo = git state file
#
# Usage:
#   zen-sync.sh --repo DIR --state-file REL --profile DIR --libdir DIR
#              [--base-file FILE] [--no-push] [--git-name NAME] [-v]
set -euo pipefail

REPO= STATE_FILE=zen-state.json PROFILE= LIBDIR=
BASE_FILE= PUSH=1 GIT_NAME="zen-sync" GIT_MAIL="zen-sync@cephalode.local" VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --libdir) LIBDIR="$2"; shift 2 ;;
    --base-file) BASE_FILE="$2"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --git-name) GIT_NAME="$2"; shift 2 ;;
    --git-mail) GIT_MAIL="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    *) echo "zen-sync: unknown arg $1" >&2; exit 2 ;;
  esac
done
: "${REPO:?--repo required}" "${PROFILE:?--profile required}" "${LIBDIR:?--libdir required}"
JQ="${JQ:-jq}"
MOZLZ4A="${MOZLZ4A:-mozlz4a}"
LSOF="${LSOF:-lsof}"
HOST="${ZEN_SYNC_HOST:-$(hostname -s)}"
[ -n "${BASE_FILE:-}" ] || BASE_FILE="$HOME/.local/state/zen-spaces/base.json"
log() { [ "$VERBOSE" = 1 ] && echo "zen-sync: $*" || echo "zen-sync: $*"; }

# ── Browser must be closed (it owns the profile while running) ──
if [ ! -d "$PROFILE" ]; then
  log "profile dir missing, nothing to do: $PROFILE"
  exit 0
fi
if "$LSOF" "$PROFILE/.parentlock" >/dev/null 2>&1; then
  log "Zen is running, skipping this cycle."
  exit 0
fi

TMP="$(mktemp -d)"
if [ "${ZEN_SYNC_KEEP:-0}" = 1 ]; then trap 'echo "zen-sync: kept $TMP"' EXIT; else trap 'rm -rf "$TMP"' EXIT; fi
mkdir -p "$(dirname "$BASE_FILE")"

# ── Repo side: pull remote changes first (soft-fail offline) ──
cd "$REPO"
if git remote | grep -q .; then
  git pull --rebase --autostash --quiet \
    || { log "WARN: git pull failed, aborting rebase and continuing locally";
         git rebase --abort 2>/dev/null || true; }
fi
STATE="$REPO/$STATE_FILE"

EMPTY='{"version":1,"spaces":[],"tabs":[],"folders":[],"groups":[],"containers":[]}'
[ -f "$STATE" ]     || echo "$EMPTY" > "$STATE"
[ -f "$BASE_FILE" ] || echo "$EMPTY" > "$BASE_FILE"

# ── Project browser -> canonical subset ──
if [ -f "$PROFILE/zen-sessions.jsonlz4" ]; then
  "$MOZLZ4A" -d "$PROFILE/zen-sessions.jsonlz4" "$TMP/raw.json"
else
  echo '{"windows":[],"spaces":[],"tabs":[],"folders":[],"groups":[]}' > "$TMP/raw.json"
fi
"$JQ" -f "$LIBDIR/project.jq" "$TMP/raw.json" > "$TMP/browser.json"
if [ -f "$PROFILE/containers.json" ]; then
  CAT="$PROFILE/containers.json"
else
  CAT="$TMP/nocontainers.json"; echo null > "$CAT"
fi
"$JQ" -s -f "$LIBDIR/projectc.jq" "$TMP/browser.json" "$CAT" > "$TMP/local.json"

# ── 3-way merge: repo (input) x base x local ──
"$JQ" --slurpfile base "$BASE_FILE" --slurpfile local "$TMP/local.json" \
      -f "$LIBDIR/merge.jq" "$STATE" > "$TMP/merged.json"
"$JQ" '.state' "$TMP/merged.json" > "$TMP/newstate.json"
"$JQ" -r '.conflicts[]?' "$TMP/merged.json" | while read -r c; do
  log "CONFLICT (browser won): $c"
done

# ── Apply merged state back to the browser ──
"$JQ" --slurpfile st "$TMP/newstate.json" -f "$LIBDIR/apply.jq" "$TMP/raw.json" \
  > "$TMP/applied.json"
if [ ! -s "$TMP/applied.json" ]; then
  log "ERROR: apply produced empty result, aborting without touching profile"
  exit 1
fi
cp "$PROFILE/zen-sessions.jsonlz4" "$PROFILE/zen-sessions.jsonlz4.zsync-backup" 2>/dev/null || true
"$MOZLZ4A" "$TMP/applied.json" "$PROFILE/zen-sessions.jsonlz4"
"$JQ" --slurpfile st "$TMP/newstate.json" -f "$LIBDIR/containers.jq" "$CAT" \
  > "$TMP/containers.new"
mv "$TMP/containers.new" "$PROFILE/containers.json"

# Idempotence check: re-projecting the applied result must equal newstate
"$JQ" -f "$LIBDIR/project.jq" "$TMP/applied.json" > "$TMP/reproj.json"
"$JQ" -s -f "$LIBDIR/projectc.jq" "$TMP/reproj.json" "$PROFILE/containers.json" > "$TMP/reproj-full.json"
if ! "$JQ" -S . "$TMP/reproj-full.json" | diff -q - <("$JQ" -S . "$TMP/newstate.json") >/dev/null; then
  log "WARN: projection of applied state differs from merged state (non-fatal)"
fi

# ── New base = what we just applied ──
cp "$TMP/newstate.json" "$BASE_FILE"

# ── Commit + push state changes ──
"$JQ" -S . "$TMP/newstate.json" > "$STATE"
if git status --porcelain -- "$STATE_FILE" | grep -q .; then
  SUMMARY="$("$JQ" -s -r '
    (.[0] // {}) as $old | (.[1] // {}) as $new |
    def cnt($s; $k): ($s[$k] // []) | length;
    "spaces:\(cnt($new;"spaces")) pins:\(cnt($new;"tabs")) folders:\(cnt($new;"folders")) containers:\(cnt($new;"containers"))" ' \
    <(git show "HEAD:$STATE_FILE" 2>/dev/null || echo null) "$STATE")"
  git add "$STATE_FILE"
  git -c user.name="$GIT_NAME" -c user.email="$GIT_MAIL" \
    commit --quiet --only -m "zen-sync($HOST): $SUMMARY" -- "$STATE_FILE"
  log "committed: $SUMMARY"
  if [ "$PUSH" = 1 ] && git remote | grep -q .; then
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    if git push --quiet origin "HEAD:$BRANCH"; then :; else
      log "WARN: git push failed, will retry next cycle"
    fi
  fi
else
  log "no state changes"
fi
log "cycle complete"
