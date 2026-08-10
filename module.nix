# Declarative Zen Browser Spaces + Containers — no Home Manager required.
#
# Works by writing/patching Zen's profile state files on login via a
# systemd.user oneshot:
#   - containers.json  (plain JSON, written directly)
#   - zen-sessions.jsonlz4  (mozlz4a decompress → jq merge → recompress)
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

  # Generate containers.json content
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

  # Generate spaces array for jq input
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

  # The jq filter that upserts spaces into zen-sessions.jsonlz4
  spacesJqFilter = spacesForce: ''
    ($declaredSpaces[0]) as $spaces |

    .spaces = (.spaces // []) |

    ([$spaces[].uuid]) as $dsUuids |
    ([.spaces[].uuid]) as $esUuids |

    .spaces = [.spaces[] |
      . as $e |
      ($spaces | map(select(.uuid == $e.uuid)) | .[0] // null) as $o |
      if $o != null then ($e * $o) else . end
    ] |
    .spaces += [$spaces[] | select(.uuid as $u | $esUuids | index($u) | not)]
    ${lib.optionalString spacesForce "| .spaces = [.spaces[] | select(.uuid as $u | $dsUuids | index($u) != null)]"}
  '';

  # The session patcher script (built as a derivation so it's in the store)
  mkSessionPatcher = {
    spacesFile,
    jqFilterFile,
  }:
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
        --slurpfile declaredSpaces ${spacesFile} \
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
    enable = lib.mkEnableOption "declarative Zen Browser spaces and containers";

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
  };

  config = lib.mkIf cfg.enable {
    # Containers: write containers.json directly (plain JSON, no compression)
    systemd.user.services.zen-containers = {
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
                nextUserContextId: (1 + ([([$base.lastUserContextId // 0, (.[1].identities // [] | map(.userContextId) | max // 0)] | max), ([.[1].identities // [] | map(.userContextId) | max // 0])] | max))
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

    # Spaces: patch zen-sessions.jsonlz4
    systemd.user.services.zen-spaces-session = let
      spacesFile = pkgs.writeText "zen-spaces.json" (spacesJson cfg.spaces);
      jqFilterFile = pkgs.writeText "zen-spaces-filter.jq" (spacesJqFilter cfg.spacesForce);
      patcher = mkSessionPatcher { inherit spacesFile jqFilterFile; };
      fullProfileDir = "${cfg.profileDir}/${cfg.profileName}";
    in {
      description = "Zen Browser declarative spaces";
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
  };
}
