{
  description = "InvenTree (0.11 - 1.5) in a systemd-nspawn container - NixOS module";

  # Only used to run `nix flake check`; consumers point their own nixpkgs at the
  # module via `inputs.inventree.inputs.nixpkgs.follows`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Evaluate the module end to end (compose / proxy-config rendering, the
      # docker-compose unit, the whole inner container system) for one version.
      evalFor = system: version: (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          {
            fileSystems."/".device = "/dev/null";
            boot.loader.grub.enable = false;
            system.stateVersion = "25.11";
            # The inner container pulls `virtualisation.docker`; whichever docker
            # the pinned nixpkgs ships may be flagged insecure by the time this
            # check runs. That is a nixpkgs-pin concern, not a module one - wave
            # it through here so the check keeps exercising the module.
            nixpkgs.config.allowInsecurePredicate =
              p: nixpkgs.lib.getName p == "docker";
            services.containers.inventree = {
              inherit version;
              enable = true;
              database.passwordFile = "/run/secrets/inventree-db";
            };
          }
        ];
      }).config.containers.inventree.config.system.build.toplevel;
    in
    {
      nixosModules.inventree = import ./module.nix;
      nixosModules.default = self.nixosModules.inventree;

      checks = forAllSystems (system: {
        eval-nginx = evalFor system "0.13.6"; # pre-0.14 nginx generation
        eval-caddy = evalFor system "0.17.14"; # 0.14-0.17 bundled-Caddy generation
        eval-v1 = evalFor system "1.1.12"; # 1.0/1.1 (last on postgres:13)
        eval-v1-latest = evalFor system "1.5.2"; # newest 1.x (renamed port vars, redis, postgres:17)
      });
    };
}
