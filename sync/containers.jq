# Rewrite containers.json from projected state ($st slurpfile).
# Input = existing containers.json (may be null if missing).
($st[0].containers // []) as $C |
{
  identities: [
    $C[] | { name, icon, color, public: (.public // true),
             userContextId, accessKey: "" }
  ] | sort_by(.userContextId),
  lastUserContextId: (([$C[].userContextId] | max) // 0),
  nextUserContextId: ((([$C[].userContextId] | max) // 0) + 1)
}
