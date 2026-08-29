#!/usr/bin/env bash
# Round-trip test for zen-sync.sh using stub mozlz4a (plain copy).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# stubs
mkdir -p "$T/bin"
cat > "$T/bin/mozlz4a" <<'EOF'
#!/usr/bin/env bash
# stub: -d in out | in out (compress) — plain copy
if [ "$1" = "-d" ]; then cp "$2" "$3"; else cp "$1" "$2"; fi
EOF
chmod +x "$T/bin/mozlz4a"
export MOZLZ4A="$T/bin/mozlz4a"
export JQ="$(command -v jq)"
export LSOF="$(command -v lsof || echo /usr/sbin/lsof)"

# git identity for the test repo
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t

# ── fixtures ──
PROFILE="$T/profile"; mkdir -p "$PROFILE"
cat > "$PROFILE/zen-sessions.jsonlz4" <<'EOF'
{
  "windows": [{"tabs": []}],
  "spaces": [
    {"uuid": "{s1}", "name": "Personal", "position": 1000, "icon": "🏠", "containerTabId": 0,
     "theme": {"type": "gradient", "gradientColors": [], "opacity": 0.5, "texture": 0},
     "hasCollapsedPinnedTabs": false}
  ],
  "tabs": [
    {"pinned": true, "hidden": false, "zenSyncId": "{p1}", "zenWorkspace": "{s1}",
     "zenEssential": false, "zenDefaultUserContextId": "true", "userContextId": 0,
     "index": 1000, "lastAccessed": 999, "groupId": null, "zenIsEmpty": false,
     "entries": [{"url": "https://example.com", "title": "Example"}]},
    {"pinned": false, "zenSyncId": "{r1}", "index": 1, "entries": [{"url": "https://news.ycombinator.com"}]}
  ],
  "folders": [],
  "groups": []
}
EOF
echo '{"identities":[{"userContextId":1,"name":"Work","icon":"briefcase","color":"blue","public":true,"accessKey":""}],"lastUserContextId":1,"nextUserContextId":2}' > "$PROFILE/containers.json"

REPO="$T/repo"; git init -q "$REPO"
cat > "$REPO/zen-state.json" <<'EOF'
{"version":1,"spaces":[],"tabs":[],"folders":[],"groups":[],"containers":[]}
EOF
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
BASE="$T/base.json"

run() { bash "$ROOT/sync/zen-sync.sh" --repo "$REPO" --state-file zen-state.json \
  --profile "$PROFILE" --libdir "$ROOT/sync" --base-file "$BASE" --no-push "$@"; }

echo "═══ cycle 1: bootstrap (browser -> repo) ═══"
run -v
jq -c '{s: (.spaces|length), t: (.tabs|length), c: (.containers|length)}' "$REPO/zen-state.json"
git -C "$REPO" log --oneline | head -3

echo "═══ cycle 2: no-op (idempotence) ═══"
run
git -C "$REPO" log --oneline | wc -l

echo "═══ cycle 3: browser edit (add pin + rename space) -> repo ═══"
jq '.tabs += [{"pinned":true,"hidden":false,"zenSyncId":"{p2}","zenWorkspace":"{s1}","zenEssential":false,"zenDefaultUserContextId":"true","userContextId":1,"index":2000,"lastAccessed":0,"groupId":null,"zenIsEmpty":false,"entries":[{"url":"https://github.com","title":"GH"}]}] | (.spaces[0].name = "Home")' "$PROFILE/zen-sessions.jsonlz4" > "$PROFILE/tmp" && mv "$PROFILE/tmp" "$PROFILE/zen-sessions.jsonlz4"
run -v
jq -c '[.spaces[].name, ([.tabs[].url])]' "$REPO/zen-state.json"

echo "═══ cycle 4: repo edit (simulating another machine) -> browser ═══"
jq '.spaces += [{"uuid":"{s2}","name":"Dev","position":2000,"icon":"💻","containerTabId":1,"theme":{"type":"gradient","gradientColors":[],"opacity":0.5,"texture":0},"hasCollapsedPinnedTabs":false}] | .containers += [{"userContextId":2,"name":"School","icon":"tree","color":"green","public":true}]' "$REPO/zen-state.json" > "$REPO/tmp" && mv "$REPO/tmp" "$REPO/zen-state.json"
run -v
jq -c '[.spaces[].name]' "$PROFILE/zen-sessions.jsonlz4"
jq -c '[.identities[].name]' "$PROFILE/containers.json"

echo "═══ cycle 5: browser delete (unpin p1) -> repo ═══"
jq '(.tabs[] | select(.zenSyncId == "{p1}") | .pinned) = false' "$PROFILE/zen-sessions.jsonlz4" > "$PROFILE/tmp" && mv "$PROFILE/tmp" "$PROFILE/zen-sessions.jsonlz4"
run -v
jq -c '[.tabs[].url]' "$REPO/zen-state.json"

echo "═══ cycle 6: repo delete (remove Dev space) -> browser ═══"
jq '.spaces = [.spaces[] | select(.uuid != "{s2}")]' "$REPO/zen-state.json" > "$REPO/tmp" && mv "$REPO/tmp" "$REPO/zen-state.json"
run -v
jq -c '[.spaces[].name]' "$PROFILE/zen-sessions.jsonlz4"
echo "═══ final repo log ═══"
git -C "$REPO" log --oneline
echo "TEST OK"
