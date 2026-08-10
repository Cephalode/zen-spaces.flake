# zen-spaces

Declarative Zen Browser **Spaces** and **Containers** for NixOS — **no Home Manager required**.

A pure NixOS module that patches Zen's profile state files (`zen-sessions.jsonlz4` and `containers.json`) via `systemd.user.services` oneshots at login.

I made this because I refuse to use home manager but still want to have a way to declare spaces and containers in Zen.

## How it works

| Feature | Mechanism |
|---|---|
| Containers | Writes `containers.json` (plain JSON) |
| Spaces | Patches `zen-sessions.jsonlz4` (mozlz4a decompress → jq merge → recompress) |

Both services check `.parentlock` with `lsof` and **skip silently if Zen is running**.

## Usage

### flake.nix

```nix
inputs.zen-spaces.url = "github:Cephalode/zen-spaces";
```

### NixOS config

```nix
{ inputs, ... }: {
  imports = [ inputs.zen-spaces.nixosModules.default ];

  programs.zen-spaces = {
    enable = true;
    user = "cephalode";

    spacesForce = true; # delete spaces not declared here
    spaces = {
      "Personal" = {
        id = "c6de089c-410d-4206-961d-ab11f988d40a";
        position = 1000;
        icon = "🏠";
      };
      "Work" = {
        id = "cdd10fab-4fc5-494b-9041-325e5759195b";
        position = 2000;
        icon = "💼";
        theme.colors = [{
          red = 100; green = 150; blue = 200;
          algorithm = "floating";
          lightness = 50;
        }];
        theme.opacity = 0.8;
      };
    };

    containersForce = true;
    containers = {
      Personal = { color = "purple"; icon = "fingerprint"; id = 1; };
      Work     = { color = "blue";   icon = "briefcase";   id = 2; };
    };
  };
}
```

## Important notes

- **Close Zen before rebuilding.** The services skip if the browser is running (detected via `.parentlock`). Run `systemctl --user start zen-containers zen-spaces-session` after the first rebuild, or reboot.
- **First run:** Zen must be opened at least once to create the profile directory (`~/.zen/<profile>/`) and `zen-sessions.jsonlz4`.
- `spacesForce = true` will delete any spaces not declared in your config.
- `containersForce = true` overwrites `containers.json` entirely. Without it, declared containers are merged with existing ones.
- Generate UUIDs for space `id` fields with `uuidgen | tr '[:upper:]' '[:lower:]'`.

## Options

See [`module.nix`](./module.nix) for the full option set.
