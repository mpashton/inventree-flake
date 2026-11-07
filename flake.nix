{
  description = "InvenTree (0.11 - 1.6) upstream docker-compose stack as a NixOS module";

  inputs = {
    # Consumers point their own nixpkgs at the module via
    # `inputs.inventree.inputs.nixpkgs.follows`. This pin is only used by checks.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, nixpkgs }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # The module also applies the overlay, so `pkgs.inventreePlugins.<name>`
      # works wherever it is imported.
      flake.nixosModules.inventree = {
        imports = [ ./module.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
      flake.nixosModules.default = self.nixosModules.inventree;

      # `lib.mkPlugin pkgs { pname; version; src; module; ... }` - see
      # lib/mk-plugin.nix for the plugin derivation contract.
      flake.lib.mkPlugin = import ./lib/mk-plugin.nix;

      # The in-tree plugin collection (plugins/<name>/default.nix).
      flake.overlays.default = final: _prev: {
        inventreePlugins = import ./plugins {
          inherit (final) lib;
          pkgs = final;
          mkPlugin = self.lib.mkPlugin final;
        };
      };

      perSystem = { system, pkgs, lib, ... }:
        let
          inventreePlugins = import ./plugins {
            inherit lib pkgs;
            mkPlugin = self.lib.mkPlugin pkgs;
          };

          # Native target: force the whole toplevel (compose / proxy rendering,
          # the systemd unit, assertions). Foreign target (Graviton etc.): force
          # option-processing + assertions only - proves the module evaluates
          # there without a foreign builder.
          mkSys = targetSystem: version: extra: nixpkgs.lib.nixosSystem {
            system = targetSystem;
            modules = [
              self.nixosModules.default
              {
                fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
                boot.loader.grub.enable = false;
                system.stateVersion = "25.11";
                nixpkgs.config.allowInsecurePredicate =
                  p: nixpkgs.lib.getName p == "docker";
                services.inventree = {
                  inherit version;
                  enable = true;
                  database.passwordFile = "/run/secrets/inventree-db";
                } // extra;
              }
            ];
          };
          evalOn = targetSystem: version: extra:
            let
              sys = mkSys targetSystem version extra;
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

          # A trivial plugin built with mkPlugin, standing in for a real one.
          fixturePlugin = self.lib.mkPlugin pkgs {
            pname = "inventree-fixture";
            version = "0.0.1";
            module = "fixture_plugin";
            slug = "fixture_slug";
            pluginConfigs = { ENABLE_PLUGINS_URL = true; PLUGIN_FIXTURE_MODE = "strict"; };
            src = pkgs.runCommand "fixture-plugin-src" { } ''
              mkdir -p $out/fixture_plugin
              echo 'PLUGIN = True' > $out/fixture_plugin/__init__.py
            '';
          };
          # The fixture plugin itself requires ENABLE_PLUGINS_URL; stating it here
          # too (same value) must not count as a conflict.
          pluginFixtures = {
            plugins = {
              fixture.package = fixturePlugin; # active by default
              wip = { path = "/srv/dev-plugin/wip_plugin"; slug = "wip"; active = false; };
            };
            pluginConfigs = { ENABLE_PLUGINS_URL = true; ENABLE_PLUGINS_APP = true; };
          };

          versions = {
            eval-nginx = "0.13.6"; # pre-0.14 nginx generation
            eval-caddy = "0.17.14"; # 0.14-0.17 bundled-Caddy generation
            eval-v1 = "1.1.12"; # 1.0/1.1 (last on postgres:13)
            eval-v1-latest = "1.7.0"; # newest 1.x (renamed port vars, redis, postgres:17)
          };
        in
        {
          legacyPackages.inventreePlugins = inventreePlugins;

          checks = lib.listToAttrs (lib.concatMap
            (target: lib.mapAttrsToList
              (name: version: { name = "${name}-${target}"; value = evalOn target version { }; })
              versions)
            [ "x86_64-linux" "aarch64-linux" ])
          // {
            # Native-only: forces the toplevel, so the plugin `.env` line and
            # the compose override mounts are all built.
            "eval-plugins-${system}" = evalOn system versions.eval-v1-latest pluginFixtures;
            # Pre-1.0 + plugins on the oldest rung: the plugin wiring builds on
            # the nginx generation, and the active-needs-1.x warning fires.
            "eval-plugins-legacy-${system}" = evalOn system "0.11.0" pluginFixtures;

            # The real in-tree plugin, through the module (linkFarm + mounts).
            # No pluginConfigs set by hand: the plugin brings ENABLE_PLUGINS_EVENTS.
            "plugin-ipn-generator-${system}" =
              let
                ipn = inventreePlugins.ipn-generator;
                sys = mkSys system versions.eval-v1-latest {
                  plugins.ipn-generator.package = ipn;
                };
                dir = sys.config.services.inventree.pluginDir;
                preStart = sys.config.systemd.services.inventree.preStart;
              in
              pkgs.runCommand "inventree-plugin-ipn-generator-check" { } ''
                test -f ${ipn}/ipn_generator/generator.py
                test "$(readlink ${dir}/ipn_generator)" = "${ipn}/ipn_generator"
                env=$(grep -o '/nix/store/[a-z0-9]*-inventree.env' ${pkgs.writeText "prestart.sh" preStart} | head -1)
                grep -qx 'INVENTREE_ENABLE_PLUGINS_EVENTS=True' "$env"
                grep -qx 'INVENTREE_PLUGINS_MANDATORY=ipngen' "$env"
                touch $out
              '';

            # Builds the plugin directory and checks its shape, the .env line
            # and the compose override mounts.
            "plugin-dir-${system}" =
              let
                sys = mkSys system versions.eval-v1-latest pluginFixtures;
                dir = sys.config.services.inventree.pluginDir;
                override = sys.config.environment.etc."inventree-docker/docker-compose.override.yml".text;
              in
              pkgs.runCommand "inventree-plugin-dir-check" { } ''
                test "$(readlink ${dir}/fixture_plugin)" = "${fixturePlugin}/fixture_plugin"
                test -f ${dir}/fixture_plugin/__init__.py
                # Dev paths are mounted at a fixed root, not at their host path
                # (a /home/<user> mount breaks upstream's init.sh glob).
                test "$(readlink ${dir}/wip_plugin)" = "/opt/inventree-dev-plugins/wip_plugin"
                grep -qF '"${dir}"' ${pkgs.writeText "override.yml" override}
                grep -qF 'source: "/srv/dev-plugin/wip_plugin"' ${pkgs.writeText "override.yml" override}
                grep -qF 'target: "/opt/inventree-dev-plugins/wip_plugin"' ${pkgs.writeText "override.yml" override}
                ! grep -qF 'target: "/srv/' ${pkgs.writeText "override.yml" override}
                touch $out
              '';

            # `active`: only active plugins' slugs reach INVENTREE_PLUGINS_MANDATORY
            # (read from the rendered inventree.env the unit's preStart installs).
            "plugin-active-${system}" =
              let
                sys = mkSys system versions.eval-v1-latest pluginFixtures;
                preStart = sys.config.systemd.services.inventree.preStart;
              in
              pkgs.runCommand "inventree-plugin-active-check" { } ''
                env=$(grep -o '/nix/store/[a-z0-9]*-inventree.env' ${pkgs.writeText "prestart.sh" preStart} | head -1)
                test -n "$env"
                grep -qx 'INVENTREE_PLUGINS_MANDATORY=fixture_slug' "$env"
                ! grep -q wip "$env" || { cat "$env"; exit 1; }
                # settings: the plugin's own, the user's, and the shared one once
                grep -qx 'INVENTREE_PLUGIN_FIXTURE_MODE=strict' "$env"
                grep -qx 'INVENTREE_ENABLE_PLUGINS_APP=True' "$env"
                test "$(grep -c '^INVENTREE_ENABLE_PLUGINS_URL=' "$env")" = 1
                grep -qx 'INVENTREE_ENABLE_PLUGINS_URL=True' "$env"
                touch $out
              '';

            # Misconfigured entries and conflicting settings fail an assertion
            # (not an evaluation error).
            "plugin-assertions-${system}" =
              let
                failedWith = extra:
                  map (a: a.message) (lib.filter (a: !a.assertion)
                    (mkSys system versions.eval-v1-latest extra).config.assertions);
                failed = plugins: failedWith { inherit plugins; };
                bothSet = failed { x = { package = fixturePlugin; path = "/srv/x"; }; };
                neither = failed { x = { }; };
                noSlug = failed { x.path = "/srv/x"; };
                dupSlug = failed {
                  a.package = fixturePlugin;
                  b = { path = "/srv/b"; slug = "fixture_slug"; };
                };
                ok = failed { x = { path = "/srv/x"; active = false; }; };

                # pluginConfigs: a second plugin that wants the opposite of the
                # fixture's ENABLE_PLUGINS_URL (spelled with the INVENTREE_ prefix
                # and as a string, to prove keys/values are normalised)
                contrary = self.lib.mkPlugin pkgs {
                  pname = "inventree-contrary"; version = "0.0.1";
                  module = "contrary"; slug = "contrary";
                  src = pkgs.runCommand "contrary-src" { } "mkdir -p $out/contrary; touch $out/contrary/__init__.py";
                  pluginConfigs.INVENTREE_ENABLE_PLUGINS_URL = "False";
                };
                twoPlugins = failed { a.package = fixturePlugin; b.package = contrary; };
                userVsPlugin = failedWith {
                  plugins.a.package = fixturePlugin;
                  pluginConfigs.ENABLE_PLUGINS_URL = false;
                };
                userVsPluginPrefixed = failedWith {
                  plugins.a.package = fixturePlugin;
                  pluginConfigs.INVENTREE_PLUGIN_FIXTURE_MODE = "lax";
                };
                agreeing = failedWith {
                  plugins.a.package = fixturePlugin;
                  pluginConfigs = { INVENTREE_ENABLE_PLUGINS_URL = "True"; ENABLE_PLUGINS_APP = true; };
                };
                msg = lib.concatStrings userVsPlugin;
              in
              assert lib.assertMsg (bothSet != [ ]) "package + path together must be rejected";
              assert lib.assertMsg (neither != [ ]) "an empty entry must be rejected";
              assert lib.assertMsg (noSlug != [ ]) "an active path entry without a slug must be rejected";
              assert lib.assertMsg (dupSlug != [ ]) "duplicate active slugs must be rejected";
              assert lib.assertMsg (ok == [ ]) "an inactive path entry needs no slug: ${toString ok}";
              assert lib.assertMsg (twoPlugins != [ ]) "two plugins disagreeing on a setting must be rejected";
              assert lib.assertMsg (userVsPlugin != [ ]) "pluginConfigs contradicting a plugin must be rejected";
              assert lib.assertMsg (userVsPluginPrefixed != [ ]) "a prefixed key contradicting a plugin must be rejected";
              assert lib.assertMsg (agreeing == [ ]) "agreeing settings must merge silently: ${toString agreeing}";
              assert lib.assertMsg
                (lib.hasInfix "INVENTREE_ENABLE_PLUGINS_URL" msg
                  && lib.hasInfix "plugin a" msg
                  && lib.hasInfix "services.inventree.pluginConfigs" msg)
                "the conflict message must name the key and both sources: ${msg}";
              pkgs.runCommand "inventree-plugin-assertions-check" { } "touch $out";
          };
        };
    };
}
