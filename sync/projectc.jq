# Merge projected session state (.[0]) with containers.json (.[1]).
# Use with: jq -s -f projectc.jq projected.json containers.json
#
# Firefox default containers carry l10nId instead of name — map them to
# their display names. Internal identities (userContextIdInternal.*) are
# browser machinery, not user state: excluded from the projection.
def l10nname:
  {
    "user-context-personal": "Personal",
    "user-context-work":     "Work",
    "user-context-banking":  "Banking",
    "user-context-shopping": "Shopping"
  };

.[0] + {
  containers: [
    (.[1].identities // [])
    | map(select(((.name // "") | startswith("userContextIdInternal")) | not))
    | map(. + { name: (.name // (l10nname[.l10nId] // ("Container " + (.userContextId | tostring)))) })
    | sort_by(.userContextId) | .[]
    | { userContextId, name, icon, color, public: (.public // true) }
  ]
}
