# inventree-compose

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
`.env`, runs `invoke wait`/`migrate`/`static`, and `docker compose up`s the
stack. Requires `virtualisation.docker` (the module enables it by default). All
InvenTree state (database, media, static, secret key) lives under `dataDir`
(`INVENTREE_EXT_VOLUME`).

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
services.serviceContainers.inventree = {
  stateVersion = "25.05";
  hostAddress = "192.168.100.2";
  localAddress = "192.168.100.15";
  docker.enable = true;
  tailscale = { enable = true; permitCertUid = "root"; };   # = certUid for 0.14+
  bindMounts = {
    "/var/lib/inventree/data"     = { hostPath = "/srv/inventree/data"; isReadOnly = false; };
    "/run/agenix/inventree-db"    = { hostPath = config.age.secrets."inventree-db".path; };
  };
  modules = [ inputs.inventree.nixosModules.default ];
  config.services.inventree-compose = {
    enable = true;
    version = "1.5.2";
    database.passwordFile = "/run/agenix/inventree-db";
  };
};
```

## Secrets

`database.passwordFile` / `smtp.passwordFile` are paths read at service start -
never copied into the store. On a host they are real paths; in a container,
bind-mount the host secret at that same path.

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
