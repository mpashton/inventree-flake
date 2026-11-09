# https://github.com/LavissaWoW/inventree-ipn-generator - assigns an Internal
# Part Number to new parts from a configurable pattern. Pure Python, using only
# what the InvenTree image ships.
#
# It reacts to part events; the `ENABLE_PLUGINS_EVENTS` switch it needs is
# declared below and merged into `services.inventree.pluginConfigs` for you.
# It is force-active by default (`active = true`, 1.x); set `active = false` to
# leave activation to the admin UI.
{ inventreePlugin, fetchFromGitHub, lib }:
inventreePlugin {
  pname = "inventree-ipn-generator";
  version = "0.1.2";
  src = fetchFromGitHub {
    owner = "LavissaWoW";
    repo = "inventree-ipn-generator";
    rev = "v.0.1.2"; # sic: upstream's tag has the extra dot
    hash = "sha256-Tt3WYu8CYaQtPOZQOzY80sOVs+cp6k6ygz1rN2urWlg=";
  };
  module = "ipn_generator";
  slug = "ipngen";
  pluginConfigs.ENABLE_PLUGINS_EVENTS = true; # it reacts to part events
  meta = {
    description = "InvenTree plugin that automatically generates and assigns Internal Part Numbers";
    homepage = "https://github.com/LavissaWoW/inventree-ipn-generator";
    license = lib.licenses.mit;
  };
}
