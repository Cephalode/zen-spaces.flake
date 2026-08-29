# Declarative Zen Browser Spaces + Containers + Pins — no Home Manager required.
#
# Works by writing/patching Zen's profile state files on login via a
# systemd.user oneshot:
#   - containers.json  (plain JSON, written directly)
#   - zen-sessions.jsonlz4  (mozlz4a decompress → jq merge → recompress)
#
# The session patcher handles four collections in zen-sessions.jsonlz4:
#   - spaces   (workspaces with icons, themes, containers)
#   - tabs     (pinned tabs with URLs, scoped to a space via workspace UUID)
#   - folders  (pinned tab folders — visual grouping in the sidebar)
#   - groups   (tab groups backing folders)
#
# The browser must be closed when the service runs. It checks the profile
# lock and skips silently if Zen is running.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.zen-spaces;

  # ─── Containers JSON ───

  containersJson = containers: builtins.toJSON {
    identities = lib.mapAttrsToList (_name: c: {
      inherit (c) name icon color;
      userContextId = c.id;
      public = true;
      accessKey = "";
    }) containers;
    lastUserContextId = lib.max 0 (
      lib.foldl' (acc: c: lib.max acc c.id) 0 (lib.attrValues containers)
    );
    nextUserContextId = 1 + lib.max 0 (
      lib.foldl' (acc: c: lib.max acc c.id) 0 (lib.attrValues containers)
    );
  };

  # ─── Spaces JSON ───

  spacesJson = spaces:
    builtins.toJSON (lib.mapAttrsToList (_name: s: {
      uuid = "{${s.id}}";
      inherit (s) name position;
      icon = s.icon;
      containerTabId = s.container or 0;
      theme = {
        type = s.theme.type or "gradient";
        gradientColors = map (c: {
          algorithm = c.algorithm or "floating";
          lightness = c.lightness or 0;
          c = [c.red c.green c.blue];
          isCustom = c.custom or false;
          isPrimary = c.primary or true;
        }) (s.theme.colors or []);
        opacity = s.theme.opacity or 0.5;
        texture = s.theme.texture or 0;
      };
      hasCollapsedPinnedTabs = false;
    }) spaces);

  # ─── Pin submodule (recursive for folder nesting) ───
  # Top-level pins include workspace + folderParentId options.
  # Child pins (nested inside .pins) inherit both from their parent.

  mkPinOptions = { includeWorkspace ? true, includeFolderParent ? true }: { name, ... }: {
    options = {
      title = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Display title.";
      };
      id = lib.mkOption {
        type = lib.types.str;
        description = "UUID v4 for the pin.";
      };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "URL to pin. Omit for folder-only pins.";
      };
      container = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Container ID to isolate this pin.";
      };
      position = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1000;
        description = "Sort order within the pin strip.";
      };
      isEssential = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Essential pins get special Zen treatment.";
      };
      isGroup = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Explicitly mark as folder. Implied if pins is non-empty.";
      };
      editedTitle = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Pin uses a custom title (sets zenStaticLabel).";
      };
      isFolderCollapsed = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Folder collapse state.";
      };
      folderIcon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Folder icon: emoji, chrome:// URL, or file:// path.";
      };
      pins = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (mkPinOptions {
          includeWorkspace = false;
          includeFolderParent = false;
        }));
        default = {};
        description = "Child pins — makes this pin a folder. Children inherit workspace and folderParentId.";
      };
    } // lib.optionalAttrs includeWorkspace {
      workspace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Space UUID to scope this pin to. Null = all spaces.";
      };
    } // lib.optionalAttrs includeFolderParent {
      folderParentId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Parent folder UUID for flat folder declaration.";
      };
    };
  };

  # ─── Pin resolution: flatten nested pins into a flat attrset ───
  # Children get folderParentId and workspace from their parent.
  # A pin with children gets isGroup = true implied.

  resolvePins = maxDepth: pins:
    let
      go = prefix: parent: depth: pins':
        lib.concatLists (lib.mapAttrsToList (name: p:
          let
            key = if prefix == null then name else "${prefix}/${name}";
            hasChildren = (p.pins or {}) != {};
            resolved = (removeAttrs p ["pins"]) // {
              isGroup = (p.isGroup or false) || hasChildren;
            } // (lib.optionalAttrs (parent != null) {
              folderParentId = parent.id;
              workspace = parent.workspace;
            });
          in
            [(lib.nameValuePair key resolved)]
            ++ (
              if hasChildren && depth >= maxDepth then
                throw "zen-spaces: pin folder '${key}' exceeds max nesting depth (${toString maxDepth})."
              else
                go key {
                  id = p.id;
                  workspace = resolved.workspace or null;
                } (depth + 1) (p.pins or {})
            )
        ) pins');
    in
      builtins.listToAttrs (go null null 0 pins);

  # ─── Tab rows from resolved pins ───

  pinsTabsJson = pins:
    let
      resolved = resolvePins 5 pins;
      nonGroupPins = lib.filterAttrs (_: p: !(p.isGroup or false)) resolved;
      hasDirectChild = fp:
        lib.any (p: !(p.isGroup or false) && (p.folderParentId or null) == fp.id)
          (lib.attrValues resolved);
      # Childless groups need a placeholder tab so Zen renders the folder
      childlessGroupPins = lib.filterAttrs (_: fp:
        (fp.isGroup or false) && !(hasDirectChild fp)
      ) resolved;
    in
      builtins.toJSON (
        # Placeholder tabs for childless groups
        (lib.mapAttrsToList (_: fp: {
          pinned = true;
          hidden = false;
          zenWorkspace = if (fp.workspace or null) == null then null else "{${fp.workspace}}";
          zenSyncId = "{${fp.id}}-empty";
          id = "{${fp.id}}-empty";
          zenEssential = false;
          zenDefaultUserContextId = null;
          zenPinnedIcon = null;
          zenIsEmpty = true;
          zenHasStaticIcon = false;
          zenGlanceId = null;
          zenIsGlance = false;
          searchMode = null;
          userContextId = 0;
          attributes = {};
          index = fp.position or 1000;
          lastAccessed = 0;
          groupId = "{${fp.id}}";
          entries = [{
            url = "about:blank";
            triggeringPrincipal_base64 = "{\"3\":{}}";
          }];
        }) childlessGroupPins)
        ++
        # Actual pinned tabs
        (lib.mapAttrsToList (_: p: {
          pinned = true;
          hidden = false;
          zenWorkspace = if (p.workspace or null) == null then null else "{${p.workspace}}";
          zenSyncId = "{${p.id}}";
          zenEssential = p.isEssential or false;
          zenDefaultUserContextId = "true";
          zenPinnedIcon = null;
          zenIsEmpty = false;
          zenHasStaticIcon = false;
          zenGlanceId = null;
          zenIsGlance = false;
          searchMode = null;
          userContextId = if (p.container or null) == null then 0 else p.container;
          attributes = {};
          index = p.position or 1000;
          lastAccessed = 0;
          groupId = if (p.folderParentId or null) != null then "{${p.folderParentId}}" else null;
        }
        // (lib.optionalAttrs ((p.url or null) != null) {
          entries = [{
            url = p.url;
            title = p.title or "";
            charset = "UTF-8";
            ID = 0;
            persist = true;
          }];
        })
        // (lib.optionalAttrs (p.editedTitle or false) {
          zenStaticLabel = p.title or "";
        })) nonGroupPins)
      );

  # ─── Folder rows from resolved group pins ───

  pinsFoldersJson = pins:
    let
      resolved = resolvePins 5 pins;
      groupPins = lib.filterAttrs (_: p: p.isGroup or false) resolved;
      hasDirectChild = fp:
        lib.any (p: !(p.isGroup or false) && (p.folderParentId or null) == fp.id)
          (lib.attrValues resolved);
    in
      builtins.toJSON (lib.mapAttrsToList (_: p: {
        pinned = true;
        splitViewGroup = false;
        id = "{${p.id}}";
        name = p.title or "";
        collapsed = p.isFolderCollapsed or false;
        saveOnWindowClose = true;
        parentId = if (p.folderParentId or null) == null then null else "{${p.folderParentId}}";
        prevSiblingInfo = { type = "start"; id = null; };
        emptyTabIds = if hasDirectChild p then [] else ["{${p.id}}-empty"];
        userIcon = if (p.folderIcon or null) == null then "" else p.folderIcon;
        workspaceId = if (p.workspace or null) == null then null else "{${p.workspace}}";
        index = p.position or 1000;
      }) groupPins);

  # ─── Group rows from resolved group pins ───

  pinsGroupsJson = pins:
    let
      resolved = resolvePins 5 pins;
      groupPins = lib.filterAttrs (_: p: p.isGroup or false) resolved;
    in
      builtins.toJSON (lib.mapAttrsToList (_: p: {
        pinned = true;
        splitView = false;
        id = "{${p.id}}";
        name = p.title or "";
        color = "zen-workspace-color";
        collapsed = p.isFolderCollapsed or false;
        saveOnWindowClose = true;
        index = p.position or 1000;
      }) groupPins);

  # ─── Session jq filter ───
  # Upserts spaces, tabs (pinned tabs), folders, and groups into
  # zen-sessions.jsonlz4. Existing entries matching by uuid/zenSyncId/id
  # are merged (declared wins); new entries are appended.

  sessionJqFilter = { spacesForce ? false, pinsForce ? false, pinsForceAction ? "remove" }: ''
    ($declaredSpaces[0]) as $spaces |
    ($declaredPins[0]) as $pins |
    ($declaredFolders[0]) as $folders |
    ($declaredGroups[0]) as $groups |

    .spaces = (.spaces // []) |
    .tabs = (.tabs // []) |
    .folders = (.folders // []) |
    .groups = (.groups // []) |

    # ── Spaces ──
    ([$spaces[].uuid]) as $dsUuids |
    ([.spaces[].uuid]) as $esUuids |
    .spaces = [.spaces[] |
      . as $e |
      ($spaces | map(select(.uuid == $e.uuid)) | .[0] // null) as $o |
      if $o != null then ($e * $o) else . end
    ] |
    .spaces += [$spaces[] | select(.uuid as $u | $esUuids | index($u) | not)]
    ${lib.optionalString spacesForce "| .spaces = [.spaces[] | select(.uuid as $u | $dsUuids | index($u) != null)]"}
    | .spaces = (.spaces | sort_by(.position)) |

    # ── Tabs (pinned tabs) ──
    # Selective merge: only override declared fields, preserve runtime state
    # (lastAccessed, browsing history, etc.)
    ([$pins[].zenSyncId]) as $dpIds |
    ([.tabs[].zenSyncId]) as $etIds |
    .tabs = [.tabs[] |
      . as $e |
      ($pins | map(select(.zenSyncId == ($e.zenSyncId // ""))) | .[0] // null) as $o |
      if $o != null then
        $e * {
          pinned: $o.pinned,
          zenEssential: $o.zenEssential,
          zenWorkspace: $o.zenWorkspace,
          zenDefaultUserContextId: $o.zenDefaultUserContextId,
          zenIsEmpty: $o.zenIsEmpty,
          userContextId: $o.userContextId,
          index: $o.index,
          groupId: $o.groupId
        }
        + (if $o | has("entries") then {entries: $o.entries} else {} end)
        + (if $o | has("zenStaticLabel") then {zenStaticLabel: $o.zenStaticLabel} else {} end)
      else . end
    ] |
    .tabs += [$pins[] | select(.zenSyncId as $id | $etIds | index($id) | not)]
    ${lib.optionalString (pinsForce && pinsForceAction == "remove") ''
      | .tabs = [.tabs[] |
        if (.pinned == true or .zenEssential == true) then
          select(.zenSyncId as $id | $dpIds | index($id) != null)
        else . end
      ]
    ''}
    | .tabs = (.tabs | sort_by(.index // 0)) |

    # ── Folders ──
    ([$folders[].id]) as $dfIds |
    ([.folders[].id]) as $efIds |
    .folders = [.folders[] |
      . as $e |
      ($folders | map(select(.id == $e.id)) | .[0] // null) as $o |
      if $o != null then ($e * $o) else . end
    ] |
    .folders += [$folders[] | select(.id as $id | $efIds | index($id) | not)]
    | .folders = (.folders | sort_by(.index // 0)) |

    # ── Groups ──
    ([$groups[].id]) as $dgIds |
    ([.groups[].id]) as $egIds |
    .groups = [.groups[] |
      . as $e |
      ($groups | map(select(.id == $e.id)) | .[0] // null) as $o |
      if $o != null then ($e * $o) else . end
    ] |
    .groups += [$groups[] | select(.id as $id | $egIds | index($id) | not)]
    | .groups = (.groups | sort_by(.index // 0))
  '';

  # ─── Session patcher script ───

  mkSessionPatcher = { slurpfiles, jqFilterFile }:
    pkgs.writeShellScript "zen-sessions-patch" ''
      set -euo pipefail

      PROFILE_DIR="$1"
      SESSIONS_FILE="$PROFILE_DIR/zen-sessions.jsonlz4"
      LOCK_FILE="$PROFILE_DIR/.parentlock"

      # Skip if browser is running
      if ${lib.getExe pkgs.lsof} "$LOCK_FILE" >/dev/null 2>&1; then
        echo "zen-spaces: Zen is running, skipping session update."
        exit 0
      fi

      # Skip if sessions file doesn't exist yet (first run)
      if [ ! -f "$SESSIONS_FILE" ]; then
        echo "zen-spaces: Sessions file not found, Zen will create it on first run."
        exit 0
      fi

      TMP_FILE="$(mktemp)"
      MODIFIED_FILE="$(mktemp)"
      BACKUP_FILE="''${SESSIONS_FILE}.backup"
      trap 'rm -f "$TMP_FILE" "$MODIFIED_FILE"' EXIT

      # Backup
      cp "$SESSIONS_FILE" "$BACKUP_FILE"

      # Decompress mozlz4a
      ${pkgs.mozlz4a}/bin/mozlz4a -d "$SESSIONS_FILE" "$TMP_FILE"

      # Apply jq filter
      ${lib.getExe pkgs.jq} \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (name: path: "--slurpfile ${name} ${path}") slurpfiles)} \
        -f ${jqFilterFile} \
        "$TMP_FILE" > "$MODIFIED_FILE"

      if [ ! -s "$MODIFIED_FILE" ]; then
        echo "zen-spaces: Modified file is empty, restoring backup."
        mv "$BACKUP_FILE" "$SESSIONS_FILE"
        exit 1
      fi

      # Recompress
      ${pkgs.mozlz4a}/bin/mozlz4a "$MODIFIED_FILE" "$SESSIONS_FILE"
      rm -f "$BACKUP_FILE"
      echo "zen-spaces: Updated zen-sessions.jsonlz4"
    '';

in {
  options.programs.zen-spaces = {
    enable = lib.mkEnableOption "declarative Zen Browser spaces, containers, and pins";

    user = lib.mkOption {
      type = lib.types.str;
      default = "sqibo";
      description = "User to run the session patcher for.";
    };

    profileName = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Zen profile directory name (e.g. 'default' → ~/.zen/default).";
    };

    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${cfg.user}.home}/.zen";
      defaultText = lib.literalExpression "\${config.users.users.\${cfg.user}.home}/.zen";
      description = "Base directory of the Zen profile.";
    };

    spacesForce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete spaces not declared here.";
    };

    spaces = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
          };
          id = lib.mkOption {
            type = lib.types.str;
            description = "UUID v4 for the space.";
          };
          position = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 1000;
          };
          icon = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          container = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = null;
          };
          theme.colors = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                red = lib.mkOption { type = lib.types.int; default = 0; };
                green = lib.mkOption { type = lib.types.int; default = 0; };
                blue = lib.mkOption { type = lib.types.int; default = 0; };
                algorithm = lib.mkOption {
                  type = lib.types.enum ["complementary" "floating" "analogous"];
                  default = "floating";
                };
                lightness = lib.mkOption { type = lib.types.int; default = 0; };
                primary = lib.mkOption { type = lib.types.bool; default = true; };
                custom = lib.mkOption { type = lib.types.bool; default = false; };
              };
            });
            default = [];
          };
          theme.opacity = lib.mkOption { type = lib.types.nullOr lib.types.float; default = 0.5; };
          theme.texture = lib.mkOption { type = lib.types.nullOr lib.types.float; default = 0.0; };
          theme.type = lib.mkOption { type = lib.types.nullOr lib.types.str; default = "gradient"; };
        };
      }));
      default = {};
    };

    # ─── Pinned tabs and folders ───

    pinsForce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Remove pinned/essential tabs not declared in pins.";
    };

    pinsForceAction = lib.mkOption {
      type = lib.types.enum ["remove" "demote"];
      default = "remove";
      description = "'remove' deletes undeclared pins; 'demote' is not yet implemented.";
    };

    pins = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule (mkPinOptions {}));
      default = {};
      description = ''
        Pinned tabs and folders. Each pin needs a unique UUID v4 `id`.
        Scope a pin to a space via `workspace = "<space-uuid>"`.
        Create folders by nesting child `pins`, or use `isGroup = true`
        with `folderParentId` for the flat form.
      '';
    };

    containersForce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete containers not declared here.";
    };

    containers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          name = lib.mkOption { type = lib.types.str; default = name; };
          color = lib.mkOption {
            type = lib.types.enum ["blue" "turquoise" "green" "yellow" "orange" "red" "pink" "purple" "toolbar"];
            default = "blue";
          };
          icon = lib.mkOption {
            type = lib.types.enum [
              "fingerprint" "briefcase" "dollar" "cart" "circle" "gift"
              "vacation" "food" "fruit" "pet" "tree" "chill"
            ];
            default = "fingerprint";
          };
          id = lib.mkOption { type = lib.types.ints.unsigned; };
        };
      }));
      default = {};
    };

    # ─── Bidirectional git sync ───

    sync.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bidirectional sync via a git repo: the repo's state file
        (`stateFile`) is the source of truth, and browser edits are
        projected, 3-way merged, committed and pushed back.
        Enables zen-sync.service + timer; disables the one-shot
        declarative services (the reconciler owns the profile files).
      '';
    };

    sync.repo = lib.mkOption {
      type = lib.types.str;
      description = "Path to the git repo that carries zen-state.json.";
    };

    sync.stateFile = lib.mkOption {
      type = lib.types.str;
      default = "zen-state.json";
      description = "State file path, relative to sync.repo.";
    };

    sync.interval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "Reconcile interval (OnUnitActiveSec).";
    };

    sync.push = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Push commits to the remote (disable to sync via pull only).";
    };

    sync.gitName = lib.mkOption {
      type = lib.types.str;
      default = "zen-sync";
    };

    sync.gitEmail = lib.mkOption {
      type = lib.types.str;
      default = "zen-sync@cephalode.local";
    };
  };

  config = lib.mkIf cfg.enable {
    # Containers: write containers.json directly (plain JSON, no compression)
    systemd.user.services.zen-containers = lib.mkIf (!cfg.sync.enable) {
      description = "Zen Browser declarative containers";
      after = [ "default.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      unitConfig = {
        ConditionUser = cfg.user;
      };
      script = let
        cjson = pkgs.writeText "zen-containers.json" (containersJson cfg.containers);
        fullProfileDir = "${cfg.profileDir}/${cfg.profileName}";
      in ''
        PDIR="${fullProfileDir}"
        if [ ! -d "$PDIR" ]; then
          echo "zen-containers: Profile dir not found: $PDIR"
          exit 0
        fi

        LOCK_FILE="$PDIR/.parentlock"
        if ${lib.getExe pkgs.lsof} "$LOCK_FILE" >/dev/null 2>&1; then
          echo "zen-containers: Zen is running, skipping."
          exit 0
        fi

        # Merge with existing containers
        EXISTING="$PDIR/containers.json"
        ${lib.optionalString (!cfg.containersForce) ''
          if [ -f "$EXISTING" ]; then
            ${lib.getExe pkgs.jq} -s '.[0] as $base |
              ($base.identities // []) as $existing |
              ([ .[1].identities // [] | .[].userContextId ]) as $declared |
              {
                identities: ($existing | map(select(.userContextId as $id | $declared | index($id) != null))) + (.[1].identities // []),
                lastUserContextId: ([([$base.lastUserContextId // 0, (.[1].identities // [] | map(.userContextId) | max // 0)] | max), ([.[1].identities // [] | map(.userContextId) | max // 0])] | max),
                nextUserContextId: (1 + ([([$base.lastUserContextId // 0, (.[1].identities // [] | map(.userContextId) | max // 0)] | max), ([.[1].identities // [] | map(.userContextId) | max // 0))] | max))
              }' \
              "$EXISTING" ${cjson} > "$PDIR/containers.json.tmp"
            mv "$PDIR/containers.json.tmp" "$EXISTING"
            echo "zen-containers: Merged containers into existing file"
            exit 0
          fi
        ''}
        cp ${cjson} "$EXISTING"
        echo "zen-containers: Wrote containers.json"
      '';
    };

    # Spaces + Pins: patch zen-sessions.jsonlz4
    systemd.user.services.zen-spaces-session = let
      hasPins = cfg.pins != {};
      spacesFile = pkgs.writeText "zen-spaces.json" (spacesJson cfg.spaces);
      pinsFile = pkgs.writeText "zen-pins.json" (pinsTabsJson cfg.pins);
      foldersFile = pkgs.writeText "zen-folders.json" (pinsFoldersJson cfg.pins);
      groupsFile = pkgs.writeText "zen-groups.json" (pinsGroupsJson cfg.pins);
      jqFilterFile = pkgs.writeText "zen-session-filter.jq" (sessionJqFilter {
        inherit (cfg) spacesForce pinsForce pinsForceAction;
      });
      patcher = mkSessionPatcher {
        slurpfiles = {
          declaredSpaces = spacesFile;
          declaredPins = pinsFile;
          declaredFolders = foldersFile;
          declaredGroups = groupsFile;
        };
        inherit jqFilterFile;
      };
      fullProfileDir = "${cfg.profileDir}/${cfg.profileName}";
    in lib.mkIf (!cfg.sync.enable) {
      description = "Zen Browser declarative spaces and pins";
      after = [ "default.target" "zen-containers.service" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      unitConfig = {
        ConditionUser = cfg.user;
      };
      script = ''
        ${patcher} "${fullProfileDir}"
      '';
    };

    # ─── Bidirectional git sync (zen-sync) ───

    systemd.user.services.zen-sync = lib.mkIf cfg.sync.enable (let
      syncDrv = pkgs.symlinkJoin {
        name = "zen-sync-lib";
        paths = [ ./sync ];
      };
      pathPkgs = with pkgs; [ git jq mozlz4a lsof ];
    in {
      description = "Zen Browser bidirectional git sync";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };
      unitConfig = {
        ConditionUser = cfg.user;
      };
      environment = {
        ZEN_SYNC_HOST = config.networking.hostName;
      };
      path = pathPkgs;
      script = ''
        exec ${pkgs.bash}/bin/bash ${syncDrv}/zen-sync.sh \
          --repo '${cfg.sync.repo}' \
          --state-file '${cfg.sync.stateFile}' \
          --profile '${cfg.profileDir}/${cfg.profileName}' \
          --libdir '${syncDrv}' \
          ${lib.optionalString (!cfg.sync.push) "--no-push"} \
          --git-name '${cfg.sync.gitName}' \
          --git-mail '${cfg.sync.gitEmail}' \
          -v
      '';
    });

    systemd.user.timers.zen-sync = lib.mkIf cfg.sync.enable {
      description = "Run zen-sync every ${cfg.sync.interval}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = cfg.sync.interval;
        Persistent = true;
      };
    };
  };
}
