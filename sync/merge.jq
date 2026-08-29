# 3-way merge of projected zen states.
#   input  = $repo  (git state file)
#   $base  = last-applied state (base.json, --slurpfile base)
#   $local = current browser projection (browser.json, --slurpfile local)
# Per-id semantics (absence counts as a value, so deletes propagate):
#   local==base, repo==base  -> keep
#   local==base              -> repo wins (config change)
#   repo==base               -> local wins (browser change)
#   local==repo              -> same change on both sides
#   else                     -> CONFLICT: browser wins, id reported
# Output: { state: <merged>, conflicts: [ "<col>:<id>" ... ] }

def byid($arr; $kf):
  reduce ($arr | .[]?) as $x ({};
    . + { ($x[$kf] | tostring): $x });

def mergedcol($b; $l; $r; $kf; $sf):
  (byid($b; $kf)) as $B | (byid($l; $kf)) as $L | (byid($r; $kf)) as $R |
  [ ($B + $L + $R) | keys[] as $id
      | ($B[$id]) as $bv | ($L[$id]) as $lv | ($R[$id]) as $rv |
      if $lv == $bv and $rv == $bv then $bv
      elif $lv == $bv then $rv
      elif $rv == $bv then $lv
      elif $lv == $rv then $lv
      else $lv end
      | select(. != null)   # deleted on the winning side -> drop
  ] | sort_by(.[$sf] // 0, .[$kf] // "");

def conflictcol($b; $l; $r; $kf):
  (byid($b; $kf)) as $B | (byid($l; $kf)) as $L | (byid($r; $kf)) as $R |
  [ ($B + $L + $R) | keys[] as $id
      | ($B[$id]) as $bv | ($L[$id]) as $lv | ($R[$id]) as $rv |
      if ($lv != $bv and $rv != $bv and $lv != $rv)
      then $id else empty end ];

{
  state: {
    version: 1,
    containers: mergedcol($base[0].containers; $local[0].containers; .containers; "userContextId"; "userContextId"),
    spaces:    mergedcol($base[0].spaces;       $local[0].spaces;       .spaces;       "uuid";   "position"),
    tabs:      mergedcol($base[0].tabs;          $local[0].tabs;          .tabs;          "zenSyncId"; "index"),
    folders:   mergedcol($base[0].folders;       $local[0].folders;       .folders;       "id";     "index"),
    groups:    mergedcol($base[0].groups;        $local[0].groups;        .groups;        "id";     "index")
  },
  conflicts:
    ( [ conflictcol($base[0].containers; $local[0].containers; .containers; "userContextId")[] | "containers:\(.)" ]
    + [ conflictcol($base[0].spaces;       $local[0].spaces;       .spaces;       "uuid")[]       | "spaces:\(.)" ]
    + [ conflictcol($base[0].tabs;          $local[0].tabs;          .tabs;          "zenSyncId")[] | "tabs:\(.)" ]
    + [ conflictcol($base[0].folders;       $local[0].folders;       .folders;       "id")[]       | "folders:\(.)" ]
    + [ conflictcol($base[0].groups;        $local[0].groups;        .groups;        "id")[]       | "groups:\(.)" ] )
}
