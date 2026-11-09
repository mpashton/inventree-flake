# inventree-flake

inventree-flake is a Nix flake for [InvenTree](https://inventree.org/) using the official upstream Docker Compose stack. Major features include:

- Select from a list of available InvenTree versions, enabling easy version upgrades
- Easily support new InvenTree releases
- Install plugins from Nix
- Directly uses the official Docker Compose stack
- Automatically configures Caddy (optional) and Postgres databases

A unique feature of this flake is that it can install any of a selection of versions of InvenTree. This enables straightforward and well-controlled upgrades. The latest patchlevel of each minor version is included, and in most cases, versions not in the list are easily added. It is also straightforward to add upstream releases.

Plugins are fully supported, and configured from Nix.  The major Inventree plugins are supported directly in this flake.  Installing plugins from source is also supported.

This flake uses the `services.inventree` option set, so it cannot be installed at the same time as the Nixpkgs Inventree package. To run both on one system, put at least one of them in a container (which you would need to do anyway).

## Plugins

Plugins can be installed from one of the following sources.

- Built-in plugins are (currently) configured within InvenTree.
- The `plugins/` directory includes a set of commonly used external Inventree plugins.  These can be installed by listing them in `services.inventree.plugins`.  `inventree-flake/plugins/ipn-generator` would be installed as follows:

```
    services.inventree.plugins = {
        ipn-generator = {};
    };
```

- Plugins can be packaged externally as flakes; see below.
- Plugins can be installed from a local directory.  Plugins are copied to the target, so this works with remote servers as well.

### Plugin flakes

Plugins can be installed from a flake source:

```nix
{

  inputs = {
    some-plugin.url = "github:yoyodyne/some-plugin";
  };

  outputs = inputs@{ self, ... }: {
    # ...

    services.inventree.plugins = {
        ipn-generator = {
          package = inputs.some-plugin.packages.${system}.default;
        };
    };
  };
}
```

To make the plugin a flake, a flake.nix must be added.  For inventree-ipn-generator, here is an example, which also sets up the metadata using the pyproject.toml file:

```nix
{
  description = "InvenTree IPN generator plugin, packaged for inventree-flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    inventree.url = "github:mpashton/inventree-flake";
    inventree.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, inventree }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f s nixpkgs.legacyPackages.${s});
      project = (builtins.fromTOML (builtins.readFile ./pyproject.toml)).project;
    in {
      packages = forAll (system: pkgs: {
        default = self.packages.${system}.inventree-ipn-generator;
        inventree-ipn-generator = inventree.lib.inventreePlugin pkgs {
          pname = "inventree-ipn-generator";
          inherit (project) version;      # single source of truth: pyproject.toml
          src = self;
          module = "ipn_generator";
          slug = "ipngen";
          pluginConfigs.ENABLE_PLUGINS_EVENTS = true;
          meta = { description = project.description; homepage = project.urls.Homepage; license = nixpkgs.lib.licenses.mit; };
        };
      });
    };
}
```

### Bare plugins

A plugin directory can be given directly to the Docker instance using the `path` option.  This can be useful for plugin development, or for quickly installing plugins that are not specifically packaged for inventree-flake.

Note that the directory is on the target host where InvenTree is running.  The directory is *not* copied from the build host to the target.

```nix
    services.inventree.plugins = {
        ipn-generator = {
          path = "/home/joe/ipn-generator-dev";
          slug = "ipngen";
          pluginConfigs.ENABLE_PLUGINS_EVENTS = true;
        };
    };
```

Note the use of `pluginConfigs`, which must be set here.  Different plugins may require different options to be turned on; some may not require any.


## Configuration


## Disk space

For a standalone server installation, at least 8GiB is recommended for root, and 4GiB for data (typically `srv/`).

On space-constrained hosts, it may be necessary to clean up an installation from time to time.

Currently, this plugin does not delete old Docker images on upgrade. Use `docker images` to find unused Docker images, and `docker image rm <imageid>` to delete them.

`nixos-collect-garbage -d` can sometimes free up significant disk space.

## todo

- more text config, less gui config
- automatically set "Check plugins on startup"
- packaged plugins for the external plugins in use (`plugins/`)


## ai stuff follows ##

A NixOS module that runs an **InvenTree** instance (releases **0.11 through 1.6**)
from its upstream production `docker-compose` stack.

It configures *just the stack* on whatever NixOS system imports it - **directly on
a host** (Docker only), or as the inner system of a container. It does **no**
nspawn/VM wrapping and does **not** join a tailnet; pair it with
[`service-container`](https://github.com/youruser/service-container) (or your own
container / host config) for that.

## ⚠️ Security

The 0.11 - 0.17 releases are **past upstream security support**. This module
exists to keep an old instance alive on an internal network while you climb the
upgrade ladder toward a current release - not for a fresh deployment. 1.x is the
current line; `1.1.12` is the last rung that runs on a `postgres:13` cluster, so
it is the staging point for the database migration before `1.2`+.

Keep the instance **off the public internet** - reach it over a tailnet or a
private network. For 0.14+ the stack's bundled Caddy expects to serve a
`*.ts.net` MagicDNS name and fetch that certificate from a local `tailscaled`.

## plugins

Plugins are installed through `services.inventree.plugins.packages`: a
list of Nix-packaged plugins (from plugin flakes or modules, from the in-tree
`plugins/` collection, or a live local directory for development). They are
linked into InvenTree's custom plugin directory from the Nix store - no pip, no
network at start, and a bad plugin fails at build time rather than at container
restart. See [Plugins](#plugins-1) below.

In Plugin Settings, activate the option "Check plugins on startup".

## What it builds

Upstream's production compose stack, verbatim for the chosen tag:

- PostgreSQL - `postgres:13` for 0.11 - 0.17, `postgres:17` for 1.x
  (override with `database.image`)
- gunicorn (InvenTree web server) + django-q (background worker)
- redis cache (1.x; profile-disabled on 0.x)
- the stack's own reverse proxy / static+media server

driven by a `systemd` unit (`inventree.service`) that renders the
`.env`, runs
`invoke wait`/`migrate`/`static`, and `docker compose up`s the stack. Requires
`virtualisation.docker` (the module enables it by default). All InvenTree state
(database, media, static, secret key) lives under
`dataDir` (`INVENTREE_EXT_VOLUME`).

### Two proxy generations

| versions | stack proxy | this module's front door |
|---|---|---|
| **0.11 - 0.13** | bundled **nginx** on `:80` | a NixOS **Caddy** in front, terminating TLS for `virtualHost` |
| **0.14 onward** | bundled **Caddy** | the bundled Caddy serves `siteUrl` on :443, fetching the `*.ts.net` cert from `tailscaled` over the socket at `tailscaleSocket` |

`caddy.enable = false` drops both and exposes one plain-HTTP port (`port`) for
your own proxy. `certUid` (read-only) reports which uid needs cert-fetch
permission - `"root"` (0.14+) or `"caddy"` (0.11-0.13) - feed it to your
container wrapper's Tailscale `permitCertUid`.

The per-tag `docker-compose.yml` + proxy config under each `<tag>/` are copied
**verbatim** from `https://github.com/inventree/InvenTree/tree/<tag>/`. The
module generates one `docker-compose.override.yml` holding only what it must
change: a pinned `postgres` image (when `database.image` is set) and the
`tailscaled.sock` mount (0.14+ with `caddy.enable`).

## Usage

### Straight on a host

```nix
imports = [ inputs.inventree.nixosModules.default ];
age.secrets.inventree-db.file = ./secrets/inventree-db.age;

services.inventree = {
  enable = true;
  version = "1.6.1";
  virtualHost = "inventree.tailnet-xxxx.ts.net";   # your MagicDNS name
  database.passwordFile = config.age.secrets.inventree-db.path;
};
# plus: a tailscaled on this host that permits `config.services.inventree.certUid`.
```

### In a service-container

```nix
services.ctrnet.instances.inventree = {
  stateVersion = "25.05";
  tailscale = { enable = true; permitCertUid = "root"; };   # = certUid for 0.14+
  modules = [ inputs.inventree.nixosModules.default ];
  config.services.inventree = {
    enable = true;
    version = "1.6.1";
    dataDir = "/srv/inventree/data";
    database.passwordFile = config.age.secrets."inventree-db".path;
  };
};
```

No `docker.enable`, no `bindMounts`: the module is container-aware. It turns on
the wrapper's docker-in-nspawn support itself, keeps the in-container paths
(`/var/lib/inventree/data`, `/run/inventree/*`) to itself, and hands the wrapper
the external directories to bind-mount there - the `dataDir` host directory and
the secret files behind `database.passwordFile` / `smtp.passwordFile`. Override
`dataDir` to move the host data directory; everything else is automatic. (Set
`docker.dataDir` on the instance if you want docker's own storage somewhere
other than `/var/lib/service-containers/<name>/docker`.)

## Secrets

`database.passwordFile` / `smtp.passwordFile` are paths read at service start -
never copied into the store. On a bare host they are used as given. Inside a
`service-container` the module treats them as **host** paths and asks the
wrapper to bind-mount each onto a fixed in-container path, so the same option
value works in either mode.

## Plugins

```nix
services.inventree.plugins = {
  packages = [
    pkgs.inventreePlugins.bulk-action                    # in-tree collection (plugins/)
    inputs.my-plugin.packages.${system}.default          # a plugin flake
    { path = "/home/me/src/wip-plugin/wip_plugin"; }     # development: live host dir
  ];
  mandatory = [ "bulk-action" ];                    # slugs; 1.x only
  extraConfig = { ENABLE_PLUGINS_URL = true; };     # per-feature switches
};
```

Every plugin is installed in InvenTree's **custom plugin directory**
(`INVENTREE_PLUGIN_DIR`). That directory is a Nix store `linkFarm` built from
`plugins.packages`: one symlink per entry, pointing at the plugin in the store.
The link targets are bind-mounted read-only, at the same paths, into the server
and worker containers (via the generated compose override) so the symlinks
resolve there. Nothing is pip-installed, nothing touches the network at start,
and nothing is written to `dataDir`; a broken plugin fails at build time.
`enablePlugins` (`INVENTREE_PLUGINS_ENABLED`) defaults on when the list is
non-empty.

### Writing a plugin

A plugin is a derivation with a fixed layout:

```
$out/<module>/                              # the plugin's Python package (or <module>.py)
passthru.inventreePlugin.module = "<module>";
```

That is the whole contract, so a plugin flake need not depend on this one.
`inventree.lib.inventreePlugin pkgs { pname; version; src; module; srcRoot ? module;
slug; inventreeVersions ? null; pluginConfigs ? { }; }` is optional sugar for it
(`srcRoot` is the path inside the source to install as `module`, e.g.
`"src/my_plugin"`; `slug` is the plugin's InvenTree `SLUG`, used to activate it;
`inventreeVersions = { min = "1.0.0"; }` makes the module warn on a mismatched
`version`).

`pluginConfigs` lists settings the plugin needs in the instance environment,
e.g. `{ ENABLE_PLUGINS_EVENTS = true; }` (string or bool values). The module
merges them into `services.inventree.pluginConfigs`, so a consumer need not
repeat them. Settings that agree merge silently (`ENABLE_PLUGINS_URL = true` and
`INVENTREE_ENABLE_PLUGINS_URL = "True"` are the same setting); a key that two
plugins - or a plugin and your own `pluginConfigs` - set to *different* values
fails the build with a message naming the key, both values and their sources.

A plugin flake exports the package plus a module that adds it:

```nix
outputs = { self, nixpkgs, inventree }: {
  packages.x86_64-linux.default = inventree.lib.inventreePlugin nixpkgs.legacyPackages.x86_64-linux {
    pname = "inventree-foo"; version = "1.2.3"; src = ./.; module = "foo";
  };
  nixosModules.default = { pkgs, ... }: {
    services.inventree.plugins = {
      packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
      mandatory = [ "foo" ];
      extraConfig.ENABLE_PLUGINS_URL = true;
    };
  };
};
```

Consumers `imports = [ foo.nixosModules.default ]`; `packages` is a list option,
so entries from several modules merge.

### Many plugins, one repo

`plugins/<name>/default.nix` is auto-discovered (like the `<tag>/` version
directories) and exposed as `pkgs.inventreePlugins.<name>` (this flake's overlay,
applied by the module) and `legacyPackages.<system>.inventreePlugins.<name>`:

```nix
# plugins/bulk-action/default.nix
{ inventreePlugin, fetchFromGitHub }:
inventreePlugin {
  pname = "inventree-bulk-action"; version = "1.2.3"; module = "bulk_action";
  src = fetchFromGitHub { owner = "..."; repo = "..."; rev = "v1.2.3"; hash = "sha256-..."; };
}
```

Adding a plugin means adding one hash-pinned directory; no repo per plugin.

### Developing a plugin

- `{ path = "/abs/dir"; }` links a live host directory (a *string*, so it is not
  copied to the store) under its basename and mounts it read-only at
  `/opt/inventree-dev-plugins/<basename>` in the containers (never under
  `/home`: the image's `init.sh` globs `/home/*` and fails if there is more than
  one entry). Edits take
  effect on the next `systemctl restart inventree`. Inside a
  `service-container` the path is also bind-mounted into the guest. The path
  must exist: a missing one fails the start rather than being created.
- To test a plugin flake before pushing:
  `nixos-rebuild switch --override-input myplugin path:$HOME/src/myplugin`.

### Notes

- **No dependency resolution.** A plugin can only import what the InvenTree
  image already ships; there is no pip step.
- Installed plugins are registered **inactive**. Activate them in the InvenTree
  admin UI (Settings → Plugins), or - on **1.x** - put their slugs in
  `plugins.mandatory` (`INVENTREE_PLUGINS_MANDATORY`), which force-activates them
  and blocks disabling from the UI. Pre-1.0 releases ignore the setting (the
  module warns but still evaluates) - activate plugins by hand there.
- Removing an entry does **not** delete its `PluginConfig` row.
- Some plugin capabilities need a per-feature master switch
  (`ENABLE_PLUGINS_URL`, `…_NAVIGATION`, `…_APP`, `…_SCHEDULE`, `…_EVENTS`,
  `…_INTERFACE`, `…_MAILS`); packaged plugins declare the ones they need
  themselves (see above), and you can set more through `pluginConfigs`. A plugin
  that adds database models (`ENABLE_PLUGINS_APP`) must be active before
  `invoke migrate` runs, so its first install may need a second
  `systemctl restart`.
- Upstream considers a custom plugin directory unsuitable for production; the
  concern is reproducibility, which store pinning addresses.
- Third-party plugin code runs inside the InvenTree server and worker containers
  with full access to the instance - vet what you add.

## Versions & upgrades

`version` is an enum over the `<tag>/` directories. Raising it is an **in-place
upgrade** against the existing `dataDir`: the new image starts against the same
database and the unit's `preStart` runs `invoke migrate` on every start.
**Downgrades are not supported.**

Add a release by dropping in a new `<tag>/` directory whose `default.nix`
declares `proxy` (`"nginx"` / `"caddy"`) and reads its verbatim
`docker-compose.yml` + proxy config. Nothing in `module.nix` changes. (Only tags
with a published `inventree/inventree:<tag>` image, not just a git tag - Docker
Hub is the source of truth.)

### The 0.13 -> 0.14 step

The proxy topology flips (nginx -> the stack's own Caddy). Also: when switching
off the 0.13 line the old containers use a different naming scheme, so tear the
running stack down by hand first (`docker rm -f $(docker ps -aq)` in the
container/host - all state is in `dataDir`). From **0.16** on, `siteUrl` (→
`INVENTREE_SITE_URL`) must be right or login fails with a CSRF error - it
defaults to `https://<virtualHost>`, so make `virtualHost` the real name.

### CORS

InvenTree's shipped `config.yaml` allows API reads from every origin, which
raises warning INVE-W16. The module overrides that: `cors.allowAll` defaults to
`false` (`INVENTREE_CORS_ORIGIN_ALLOW_ALL`), on every supported release. Same-origin
use - the web UI itself - needs no CORS at all. Add `cors.whitelist = [ "https://other.example" ]`
(`INVENTREE_CORS_ORIGIN_WHITELIST`) only for another hostname or a separate web app that calls
the API from browser JavaScript. The Caddy `Access-Control-Allow-Origin *` on `/static` and
`/media` is upstream's and is unaffected.

### The 0.17 -> 1.0 step and the PostgreSQL wall

1.0 is a rewrite. The compose file jumps to `postgres:17`, and **InvenTree 1.2+
hard-requires PostgreSQL 14+**. Postgres major versions are on-disk incompatible,
so this is a dump/restore, not a transparent bump:

1. Get to **1.1.12** with `database.image = "postgres:13"` pinned (it still runs
   on your existing 13 cluster). Verify.
2. Follow <https://inventree.org/blog/2026/02/12/db-update>: `pg_dump` the 13
   cluster, move the old `pgdb` dir aside, set `database.image = "postgres:17"`
   (or `null`), restore into the fresh 17 cluster, then climb 1.2 -> 1.6.

The module refuses to evaluate a `1.2`+ version while `database.image` points at
a `:13` tag.

### Known upgrade gotcha: 0.11 -> 0.12/0.13

The first migration to 0.12+ (`part.0109_auto_20230517_1048`) queries the
`common_customunit` table before the migration that creates it. The stack fails
with `current transaction is aborted` / `relation "common_customunit" does not
exist`. Fix - apply the `common` migrations first, once, by hand:

```sh
cd /etc/inventree-docker
docker compose run --rm inventree-server python InvenTree/manage.py migrate common 0020_customunit
docker compose run --rm inventree-server invoke migrate
```

then `systemctl start inventree`.

## Options

See the `options.services.inventree` block in [`module.nix`](./module.nix).
