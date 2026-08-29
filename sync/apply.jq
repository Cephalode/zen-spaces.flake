# Apply projected state ($st slurpfile, merged form) to the decompressed
# zen-sessions JSON (input). Absence = delete (tabs are demoted, not closed).
# Existing rows keep runtime state; only declarative fields are overridden.
. as $orig |
($st[0]) as $S |
([$S.spaces[]?.uuid]) as $spaceIds |
([$S.tabs[]?.zenSyncId]) as $tabIds |
([$S.folders[]?.id]) as $folderIds |
([$S.groups[]?.id]) as $groupIds |
([$orig.tabs[]?.zenSyncId]) as $origTabIds |
([$orig.spaces[]?.uuid]) as $origSpaceIds |
([$orig.folders[]?.id]) as $origFolderIds |
([$orig.groups[]?.id]) as $origGroupIds |
([($orig.folders // [])[]?.id] - $folderIds) as $deadFolders |

$orig * {

  spaces:
    ( [$orig.spaces[]? | select(.uuid as $u | $spaceIds | index($u))
         | . as $e | ($S.spaces[]? | select(.uuid == $e.uuid)) as $p | ($e * $p)]
      + [$S.spaces[]? | select(.uuid as $u | $origSpaceIds | index($u) | not)]
    ) | sort_by(.position // 0),

  tabs:
    ( # untouched rows: regular tabs + folder placeholder rows
      # (placeholders of deleted folders are removed)
      [ $orig.tabs[]?
        | select(.pinned != true or .zenIsEmpty == true)
        | if (.groupId as $g | $deadFolders | index($g)) then empty else . end ]
      +
      # pinned rows present in state: override declarative fields only
      [ $orig.tabs[]?
        | select(.pinned == true and .zenIsEmpty != true)
        | . as $e |
        if ($e.zenSyncId as $id | $tabIds | index($id)) then
          ($S.tabs[]? | select(.zenSyncId == $e.zenSyncId)) as $p |
          $e * {
            pinned: true,
            zenWorkspace: $p.zenWorkspace,
            userContextId: ($p.userContextId // 0),
            index: ($p.index // 1000),
            groupId: $p.groupId,
            zenEssential: ($p.zenEssential // false)
          }
          + (if $p.zenStaticLabel == null then {} else {zenStaticLabel: $p.zenStaticLabel} end)
          + (if ($p.url != null and (($e.entries[0].url // "") != $p.url))
             then {entries: ((($e.entries // [])[0] // {}) + {url: $p.url}) + ($e.entries // [])[1:]}
             else {} end)
        else
          # pinned in browser, absent in state -> demote to a regular tab
          ($e * {pinned: false, zenEssential: false, zenIsEmpty: false, groupId: null})
        end ]
      +
      # new pins declared in state
      [ $S.tabs[]? | select(.zenSyncId as $id | $origTabIds | index($id) | not)
        | {
            pinned: true, hidden: false,
            zenWorkspace: .zenWorkspace,
            zenSyncId: .zenSyncId,
            zenEssential: (.zenEssential // false),
            zenDefaultUserContextId: "true",
            zenPinnedIcon: null, zenIsEmpty: (.zenIsEmpty // false),
            zenHasStaticIcon: false,
            zenGlanceId: null, zenIsGlance: false, searchMode: null,
            userContextId: (.userContextId // 0), attributes: {},
            index: (.index // 1000), lastAccessed: 0,
            groupId: .groupId,
            entries: (if (.zenIsEmpty // false) then [{ url: "about:blank", triggeringPrincipal_base64: "{\"3\":{}}" }]
              elif .url == null then []
              else [{ url: .url, title: (.title // ""), charset: "UTF-8", ID: 0, persist: true }]
            end)
          }
          + (if .zenStaticLabel != null then {zenStaticLabel: .zenStaticLabel} else {} end)
      ]
    ),

  folders:
    ( [$orig.folders[]? | select(.id as $i | $folderIds | index($i))
         | . as $e | ($S.folders[]? | select(.id == $e.id)) as $p |
           ($e * { name: $p.name, collapsed: $p.collapsed, parentId: $p.parentId,
                   userIcon: $p.userIcon, workspaceId: $p.workspaceId, index: $p.index })]
      + [$S.folders[]? | select(.id as $i | $origFolderIds | index($i) | not)
        | { pinned: true, splitViewGroup: false, id: .id, name: (.name // ""),
            collapsed: (.collapsed // false), saveOnWindowClose: true,
            parentId: .parentId, prevSiblingInfo: {type: "start", id: null},
            emptyTabIds: [], userIcon: (.userIcon // ""),
            workspaceId: .workspaceId, index: (.index // 1000) } ]
    ) | sort_by(.index // 0),

  groups:
    ( [$orig.groups[]? | select(.id as $i | $groupIds | index($i))
         | . as $e | ($S.groups[]? | select(.id == $e.id)) as $p |
           ($e * { name: $p.name, color: $p.color, collapsed: $p.collapsed, index: $p.index })]
      + [$S.groups[]? | select(.id as $i | $origGroupIds | index($i) | not)
        | { pinned: true, splitView: false, id: .id, name: (.name // ""),
            color: (.color // "zen-workspace-color"), collapsed: (.collapsed // false),
            saveOnWindowClose: true, index: (.index // 1000) } ]
    ) | sort_by(.index // 0)
}
