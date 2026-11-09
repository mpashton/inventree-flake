# In-tree plugin collection. Every subdirectory <name>/ holding a default.nix is
# one plugin, called with `{ inventreePlugin, ...pkgs }` and exposed as
# `pkgs.inventreePlugins.<name>` (overlay) / `legacyPackages.<system>.inventreePlugins.<name>`.
#
#   plugins/my-plugin/default.nix:
#     { inventreePlugin, fetchFromGitHub }:
#     inventreePlugin {
#       pname = "inventree-my-plugin";
#       version = "1.2.3";
#       src = fetchFromGitHub { owner = "..."; repo = "..."; rev = "v1.2.3"; hash = "sha256-..."; };
#       module = "my_plugin";
#     }
#
# To add a plugin, drop in a directory; nothing else changes.
{ lib, pkgs, inventreePlugin }:
let
  dirs = lib.filterAttrs
    (name: type: type == "directory" && builtins.pathExists (./. + "/${name}/default.nix"))
    (builtins.readDir ./.);
in
lib.mapAttrs
  (name: _: lib.callPackageWith (pkgs // { inherit inventreePlugin; }) (./. + "/${name}") { })
  dirs
