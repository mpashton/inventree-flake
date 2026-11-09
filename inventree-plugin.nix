# Package an InvenTree plugin for `services.inventree.plugins`.
#
# The contract a plugin derivation has to meet is tiny, so a plugin flake need
# not depend on this one - this is just sugar for meeting it:
#
#   $out/<module>                      the plugin's Python package directory (or a
#                                      single `<name>.py`), as InvenTree's custom
#                                      plugin directory loader expects
#   passthru.inventreePlugin.module    that `<module>` entry name
#
# Arguments:
#   pname, version, src   as for any derivation (fetchFromGitHub / fetchPypi / ./.)
#   module                entry name under $out (e.g. "my_plugin", or "my_plugin.py")
#   srcRoot               path inside the unpacked source to install as `module`
#                         (default: `module`; use "src/my_plugin" for a src layout)
#   slug                  the plugin's InvenTree slug (its `SLUG`; required). It is what
#                         `active` plugins are force-activated by
#   inventreeVersions     optional { min ? "x.y.z"; max ? "x.y.z"; } - the module
#                         warns when the selected InvenTree version is outside it
#   pluginConfigs         optional attrset of settings the plugin needs in the
#                         instance environment, e.g. { ENABLE_PLUGINS_EVENTS = true; }
#                         (string or bool values, as for `services.inventree.pluginConfigs`).
#                         The module merges them into its own and flags conflicts.
#   meta                  usual derivation meta
#
# Usage:  inventreePlugin pkgs { pname = "inventree-foo"; version = "1.2.3"; src = ...; module = "foo"; slug = "foo"; }
pkgs:
{ pname
, version
, src
, module
, srcRoot ? module
, slug
, inventreeVersions ? null
, pluginConfigs ? { }
, meta ? { }
}:
assert pkgs.lib.assertMsg
  (pkgs.lib.all (v: pkgs.lib.isString v || pkgs.lib.isBool v) (pkgs.lib.attrValues pluginConfigs))
  "inventreePlugin ${pname}: pluginConfigs values must be strings or booleans";
pkgs.stdenvNoCC.mkDerivation {
  inherit pname version src meta;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r ${pkgs.lib.escapeShellArg srcRoot} "$out/"${pkgs.lib.escapeShellArg module}
    chmod -R u+w "$out"
    find "$out" -name __pycache__ -type d -prune -exec rm -rf {} +
    runHook postInstall
  '';

  passthru.inventreePlugin = { inherit module slug inventreeVersions pluginConfigs; };
}
