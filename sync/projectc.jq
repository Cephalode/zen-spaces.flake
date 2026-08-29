# Merge projected session state (.[0]) with containers.json (.[1]).
# Use with: jq -s -f projectc.jq projected.json containers.json
.[0] + {
  containers: [
    (.[1].identities // []) | sort_by(.userContextId) | .[]
    | { userContextId, name, icon, color, public }
  ]
}
