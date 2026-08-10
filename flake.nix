{
  description = "Declarative Zen Browser spaces and containers — NixOS module, no Home Manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      nixosModules.default = import ./module.nix;
      nixosModules.zen-spaces = self.nixosModules.default;

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          # Eval test: module + enable=true must evaluate cleanly
          eval-test = pkgs.runCommand "zen-spaces-eval-test" { } ''
            ${nixpkgs.lib.getExe pkgs.nix} eval --impure --expr '
              let
                nixpkgs = builtins.getFlake "${nixpkgs}";
                sys = nixpkgs.lib.nixosSystem {
                  system = "${system}";
                  modules = [
                    (import ${./module.nix})
                    {
                      users.users.test.home = "/home/test";
                      programs.zen-spaces = {
                        enable = true;
                        user = "test";
                        spaces.Test.id = "aaaabbbb-cccc-dddd-eeee-ffffffffffff";
                        containers.Test = { color = "blue"; icon = "fingerprint"; id = 1; };
                      };
                    }
                  ];
                };
              in assert sys.config.programs.zen-spaces.enable; "ok"
            ' > $out
            echo "passed" >> $out
          '';
        });
    };
}
