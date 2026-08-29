# Full Zen session store -> projected declarative subset (canonical form).
# Only declarative fields survive; runtime state (history, lastAccessed, …)
# is dropped so the projected state is stable across reconciles.
{
  version: 1,
  spaces: [
    (.spaces // []) | sort_by(.position // 0) | .[]
    | { uuid, name, position, icon, containerTabId,
        hasCollapsedPinnedTabs, theme }
  ],
  tabs: [
    (.tabs // [])
    | map(select(.pinned == true and .zenIsEmpty != true))
    | sort_by(.index // 0) | .[]
    | { zenSyncId,
        url: (.entries[0].url // null),
        title: ((.entries[0].title // "") | if . == "" then null else . end),
        zenWorkspace, userContextId, index, groupId,
        zenEssential, zenStaticLabel }
  ],
  folders: [
    (.folders // []) | sort_by(.index // 0) | .[]
    | { id, name, collapsed, parentId, userIcon, workspaceId, index }
  ],
  groups: [
    (.groups // []) | sort_by(.index // 0) | .[]
    | { id, name, color, collapsed, index }
  ]
}
