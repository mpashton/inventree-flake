{
  description = "InvenTree (0.11 - 1.5) upstream docker-compose stack as a NixOS module";

  inputs = {
    # Consumers point their own nixpkgs at the module via
    # `inputs.inventree.inputs.nixpkgs.follows`. This pin is only used by checks.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, nixpkgs }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      flake.nixosModules.inventree-compose = import ./module.nix;
      flake.nixosModules.default = self.nixosModules.inventree-compose;

      perSystem = { system, pkgs, lib, ... }:
        let
          # Native target: force the whole toplevel (compose / proxy rendering,
          # the systemd unit, assertions). Foreign target (Graviton etc.): force
          # option-processing + assertions only - proves the module evaluates
          # there without a foreign builder.
          evalOn = targetSystem: version:
            let
              sys = nixpkgs.lib.nixosSystem {
                system = targetSystem;
                modules = [
                  self.nixosModules.default
                  {
                    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
                    boot.loader.grub.enable = false;
                    system.stateVersion = "25.11";
                    nixpkgs.config.allowInsecurePredicate =
                      p: nixpkgs.lib.getName p == "docker";
                    services.inventree-compose = {
                      inherit version;
                      enable = true;
                      database.passwordFile = "/run/secrets/inventree-db";
                    };
                  }
                ];
              };
              probe =
                if targetSystem == system
                then sys.config.system.build.toplevel.drvPath
                else builtins.deepSeq
                  (map (a: a.assertion) sys.config.assertions ++ sys.config.warnings)
                  "eval-ok";
            in
            pkgs.runCommand "inventree-check-${version}-${targetSystem}" { } ''
              echo ${lib.escapeShellArg probe} > "$out"
            '';

          versions = {
            eval-nginx = "0.13.6"; # pre-0.14 nginx generation
            eval-caddy = "0.17.14"; # 0.14-0.17 bundled-Caddy generation
            eval-v1 = "1.1.12"; # 1.0/1.1 (last on postgres:13)
            eval-v1-latest = "1.5.2"; # newest 1.x (renamed port vars, redis, postgres:17)
          };
        in
        {
          checks = lib.listToAttrs (lib.concatMap
            (target: lib.mapAttrsToList
              (name: version: { name = "${name}-${target}"; value = evalOn target version; })
              versions)
            [ "x86_64-linux" "aarch64-linux" ]);
        };
    };
}
