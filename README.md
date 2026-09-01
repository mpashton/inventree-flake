# inventree-flake

A flake for [InvenTree](https://inventree.org/) using the official upstream
Docker Compose stack.

A unique feature of this flake is that you can choose to run any version of
InvenTree (from a wide selection), and not only the latest packaged release.
This allows relatively straightforward and well-controlled version upgrades.
In most cases, versions not in the list are easily added.

It is also easy to run multiple instances of InvenTree on the same server, with
different versions if desired. (`server-farm` can help with this.)

## plugins

This flake supports installing plugins through the `plugins` options. This works
by generating the `plugins.txt` file, which on container restart, triggers a
rebuild of the plugins directory.

Unfortunately, this mechanism is rather fragile, as problems with obtaining,
building, and installing plugins do not surface until the container is being
restarted, and manual action is required when changing the plugin list. This
renders configuration not only inconvenient but effectively impure, even if the
plugins are version-pinned (as the AI strenuously recommends below). In the
future, plugins will only be loaded from Nix modules.

For now, observe the following:

1. In Plugin Settings, activate the option "Check plugins on startup".

2. After editing the module list and reinstalling the container, run the
following as root on the container host:

  rm -rf /srv/inventree/data/env /srv/inventree/data/.nix-plugins.stamp
  systemctl restart inventree-compose

## todo

- plugin flakes
- only support plugin flakes / modules
- more text config, less gui config
- generate config.yaml
- automatically set "Check plugins on startup"


## ai stuff follows ##

A NixOS module that runs an **InvenTree** instance (releases **0.11 through 1.5**)
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

## What it builds

Upstream's production compose stack, verbatim for the chosen tag:

- PostgreSQL - `postgres:13` for 0.11 - 0.17, `postgres:17` for 1.x
  (override with `database.image`)
- gunicorn (InvenTree web server) + django-q (background worker)
- redis cache (1.x; profile-disabled on 0.x)
- the stack's own reverse proxy / static+media server

driven by a `systemd` unit (`inventree-compose.service`) that renders the
`.env` (and, when `plugins` is set, a `plugins.txt`), runs
`invoke wait`/`migrate`/`static`, and `docker compose up`s the stack. Requires
`virtualisation.docker` (the module enables it by default). All InvenTree state
(database, media, static, secret key, and the plugin virtualenv) lives under
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

services.inventree-compose = {
  enable = true;
  version = "1.5.2";
  virtualHost = "inventree.tailnet-xxxx.ts.net";   # your MagicDNS name
  database.passwordFile = config.age.secrets.inventree-db.path;
};
# plus: a tailscaled on this host that permits `config.services.inventree-compose.certUid`.
```

### In a service-container

```nix
services.serviceContainers.instances.inventree = {
  stateVersion = "25.05";
  tailscale = { enable = true; permitCertUid = "root"; };   # = certUid for 0.14+
  modules = [ inputs.inventree.nixosModules.default ];
  config.services.inventree-compose = {
    enable = true;
    version = "1.5.2";
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
services.inventree-compose.plugins = {
  external = [
    "inventree-brother-plugin"
    "inventree-bulk-plugin==1.2.3"
    "git+https://github.com/example/inventree-foo@v0.4.0"
  ];
  mandatory = [ "inventree-brother" ];              # slugs; 1.x only
  extraConfig = { ENABLE_PLUGINS_URL = true; };     # per-feature switches
};
```

`plugins.external` is a list of **pip requirement specifiers** - a bare name, a
pinned `name==version`, a `git+https://…@ref` URL, or a wheel URL. They are
written to `<dataDir>/plugins.txt`; when the list is non-empty the module sets
`INVENTREE_PLUGINS_ENABLED=True` and the unit's `preStart` runs `invoke plugins`
(`pip install -r plugins.txt`).

- **Persistent venv.** The upstream *production* image has no virtualenv - it
  runs off its baked system packages, so anything pip-installed into a
  short-lived task container is lost. When `plugins.external` is set the module
  points `INVENTREE_PY_ENV` at `<dataDir>/env`; the image builds that venv
  (`--system-site-packages`, so InvenTree's own deps still resolve) on the next
  start and the plugins then survive restarts. Changing `version` deletes and
  rebuilds the venv - the image never rebuilds it for a new Python - and
  reinstalls the plugins.
- **Pin every entry.** The install runs `pip install -U`, so an unpinned name
  floats to the newest release whenever the list changes.
- **This is the one place the module touches live PyPI**, and only when the
  rendered `plugins.txt` changes or `version` moves - a stamp file in `dataDir`
  records the last applied content, so steady-state restarts make no network
  calls. External plugins therefore need no module support: publish the repo and
  add its `git+https://…@tag` specifier.
- A failed install **aborts the unit start** (no `|| true`); it is retried on the
  next boot. A transient PyPI/git outage will block a restart while the list has
  unapplied changes.
- Installed plugins are registered **inactive**. Activate them in the InvenTree
  admin UI (Settings → Plugins), or - on **1.x** - put their slugs in
  `plugins.mandatory` (`INVENTREE_PLUGINS_MANDATORY`), which force-activates them
  and blocks disabling from the UI. Pre-1.0 releases ignore the setting (the
  module warns but still evaluates) - activate plugins by hand there.
- Removing an entry from `plugins.external` does **not** uninstall the package or
  delete its `PluginConfig` row - pip never prunes.
- Some plugin capabilities need a per-feature master switch
  (`ENABLE_PLUGINS_URL`, `…_NAVIGATION`, `…_APP`, `…_SCHEDULE`, `…_EVENTS`,
  `…_INTERFACE`, `…_MAILS`); set them through `plugins.extraConfig`. A plugin
  that adds database models (`ENABLE_PLUGINS_APP`) must be active before
  `invoke migrate` runs, so its first install may need a second
  `systemctl restart`.
- Third-party plugin code runs inside the InvenTree server and worker containers
  with full access to the instance - vet what you add.

`plugins.pluginDir` is an offline alternative: point it at a directory of plain
plugin packages (a Nix store path works, so a downstream flake can hand over a
`symlinkJoin` of built plugin sources). Its contents are `rsync --delete`d into
`<dataDir>/plugins` on every start and `INVENTREE_PLUGIN_DIR` is set. Upstream
considers this route unsuitable for production - prefer `plugins.external` for
anything on PyPI.

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

### The 0.17 -> 1.0 step and the PostgreSQL wall

1.0 is a rewrite. The compose file jumps to `postgres:17`, and **InvenTree 1.2+
hard-requires PostgreSQL 14+**. Postgres major versions are on-disk incompatible,
so this is a dump/restore, not a transparent bump:

1. Get to **1.1.12** with `database.image = "postgres:13"` pinned (it still runs
   on your existing 13 cluster). Verify.
2. Follow <https://inventree.org/blog/2026/02/12/db-update>: `pg_dump` the 13
   cluster, move the old `pgdb` dir aside, set `database.image = "postgres:17"`
   (or `null`), restore into the fresh 17 cluster, then climb 1.2 -> 1.5.

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

then `systemctl start inventree-compose`.

## Options

See the `options.services.inventree-compose` block in [`module.nix`](./module.nix).
