# inventree-legacy-container

A NixOS module that runs an **InvenTree** instance (releases **0.11 through 1.5**)
from its upstream production `docker-compose` stack, inside a `systemd-nspawn`
container, reachable over Tailscale.

## ⚠️ Security

The 0.11 - 0.17 releases are **past upstream security support**. This module
exists to keep an old instance alive on an internal network while you climb the
upgrade ladder toward a current release - not for a fresh deployment. 1.x is the
current line; `1.1.12` is the last rung that still runs on a `postgres:13`
cluster, so it is the staging point for the database migration before `1.2`+.

By default the instance is published **only to your tailnet**. The container
turns its own firewall off and relies on the private veth link not being
routable off-box. **Do not add a public virtual host or ACME.** If you set
`tailscale.enable = false`, restricting access to the container becomes your
responsibility.

## What it builds

A single nspawn container running upstream's production compose stack verbatim
for the chosen tag:

- PostgreSQL - `postgres:13` for 0.11 - 0.17, `postgres:17` for 1.x
  (override with `database.image`)
- gunicorn (InvenTree web server)
- django-q (background worker)
- redis cache (1.x; profile-disabled on 0.x)
- the stack's own reverse proxy / static+media server

plus, in the container, Docker itself and Tailscale. All InvenTree state
(database, media, static, secret key) lives in one host directory (`dataDir`)
bind-mounted in as `INVENTREE_EXT_VOLUME`.

### Two proxy generations

| versions | stack proxy | how the tailnet sees it |
|---|---|---|
| **0.11 - 0.13** | bundled **nginx** on `:80` | the module runs its own NixOS **Caddy** in front, terminating TLS for `virtualHost` with a `tailscale cert` |
| **0.14 onward** | bundled **Caddy** | it faces the tailnet **directly**, serving `siteUrl` and fetching the `*.ts.net` certificate straight from the container's `tailscaled` |

The per-tag `docker-compose.yml` and proxy config (`nginx.prod.conf` or
`Caddyfile`) under each `<tag>/` directory are copied **verbatim** from
`https://github.com/inventree/InvenTree/tree/<tag>/`. The module generates one
extra compose file at runtime, `docker-compose.override.yml`, holding only what
it must change: the `tailscaled.sock` mount (caddy generation) and a pinned
`postgres` image (when `database.image` is set).

## Requirements

- A NixOS host with nested containers enabled (the default) and enough
  capabilities for Docker-in-nspawn - the module sets the needed
  `additionalCapabilities` and `--system-call-filter=bpf` itself.
- `nixpkgs` >= 25.05 for the consumer system.
- **HTTPS certificates enabled for your tailnet** (Tailscale admin console) -
  required for both generations.

## Usage

```nix
{
  inputs.inventree.url = "github:youruser/inventree-legacy-container";
  inputs.inventree.inputs.nixpkgs.follows = "nixpkgs";

  # in your host configuration:
  imports = [ inputs.inventree.nixosModules.default ];

  age.secrets.inventree-db-password.file = ./secrets/inventree-db-password.age;

  services.containers.inventree = {
    enable = true;
    version = "0.17.14";
    hostname = "inventree";
    stateVersion = "25.11";                        # set once, then leave
    virtualHost = "inventree.tailnet-xxxx.ts.net"; # your MagicDNS name
    database.passwordFile = config.age.secrets.inventree-db-password.path;
  };
}
```

### Fronting it with your own proxy instead of Tailscale

```nix
services.containers.inventree = {
  enable = true;
  tailscale.enable = false;
  caddy.enable = false;      # 0.11-0.13: stack nginx on :port is yours to proxy.
                             # 0.14 onward: stack Caddy serves `siteUrl` plain, on :port.
  siteUrl = "https://inventree.example.com";  # 0.14+: whatever your proxy presents
  database.passwordFile = "/run/secrets/inventree-db";
};
```

## Secrets

Every secret is a **host path** to a file the module bind-mounts read-only into
the container and reads at service start - nothing is copied into the Nix store.
Wire them with agenix / sops-nix / plain files as you like; just make sure the
file exists before `container@<hostname>.service` starts.

| option | required | contents |
|---|---|---|
| `database.passwordFile` | yes | PostgreSQL password for `database.user` |
| `smtp.passwordFile` | when `smtp.host` is set | SMTP password |
| `tailscale.authKeyFile` | no | Tailscale auth key for non-interactive join |

## Versions & upgrades

`version` is an enum over the `<tag>/` directories. Raising it is an **in-place
upgrade** against the existing `dataDir`: the new image starts against the same
database and the container's `preStart` runs `invoke migrate` on every start.
**Downgrades are not supported.**

Add a release by dropping in a new `<tag>/` directory whose `default.nix`
declares `proxy` (`"nginx"` / `"caddy"`) and reads its verbatim
`docker-compose.yml` + proxy config. Nothing in `module.nix` changes.

### The 0.13 -> 0.14 step

The proxy topology flips here (nginx -> the stack's own Caddy). The module
handles the mechanics; nothing to do beyond the version bump. Also note: when
switching off the 0.13 line the old containers use a different naming scheme, so
tear the running stack down by hand first (`docker rm -f $(docker ps -aq)` inside
the container - all state is in `dataDir`). From **0.16** on, `INVENTREE_SITE_URL`
(set from the `siteUrl` option) must be correct or login fails with a CSRF error;
it defaults to `https://<virtualHost>`, so make `virtualHost` the real MagicDNS
name.

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
a `:13` tag, to catch this before the stack crash-loops.

### Known upgrade gotcha: 0.11 -> 0.12/0.13

The first migration to 0.12+ (`part.0109_auto_20230517_1048`) calls into the
unit registry, which queries the `common_customunit` table - but Django orders
`part.0109` *before* the migration that creates that table
(`common.0020_customunit`). The stack fails to start with
`current transaction is aborted` / `relation "common_customunit" does not exist`.

Fix: apply the `common` migrations first, once, by hand, then let the module
finish:

```sh
cd /etc/inventree-docker
docker compose run --rm inventree-server python InvenTree/manage.py migrate common 0020_customunit
docker compose run --rm inventree-server invoke migrate
```

then `systemctl start inventree-compose`.

## Options

See the `options.services.containers.inventree` block in [`module.nix`](./module.nix).
