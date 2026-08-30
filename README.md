# inventree-legacy-container

A NixOS module that runs a **legacy InvenTree** instance (releases **0.11.0,
0.12.10, 0.13.6** — the pre-0.14 "nginx reverse proxy" generation) from its
upstream production `docker-compose` stack, inside a `systemd-nspawn` container,
reachable over Tailscale.

## ⚠️ Security

These InvenTree releases are **years past upstream security support**. This
module is for keeping an old instance alive on an internal network while you plan
a real migration — not for a fresh deployment.

By default the instance is published **only to your tailnet** (Tailscale inside
the container, Caddy terminating TLS with a `tailscale cert`). The container also
turns its own firewall off and relies on the private veth link not being
routable off-box. **Do not add a public virtual host or ACME.** If you set
`tailscale.enable = false`, restricting access to the container becomes your
responsibility.

## What it builds

A single nspawn container running upstream's production compose stack verbatim
for the chosen tag:

- PostgreSQL 13
- gunicorn (InvenTree web server)
- django-q (background worker)
- nginx (the stack's own reverse proxy / static+media server)

plus, in the container, Docker itself, Tailscale, and Caddy fronting the stack.
All InvenTree state (database, media, static, secret key) lives in one host
directory (`dataDir`) bind-mounted in as `INVENTREE_EXT_VOLUME`.

The per-tag `docker-compose.yml` and `nginx.prod.conf` under each `<tag>/`
directory are copied verbatim from
`https://github.com/inventree/InvenTree/tree/<tag>/docker/production`.

## Requirements

- A NixOS host with nested containers enabled (the default) and enough
  capabilities for Docker-in-nspawn — the module sets the needed
  `additionalCapabilities` and `--system-call-filter=bpf` itself.
- `nixpkgs` ≥ 25.05 for the consumer system.

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
    version = "0.13.6";
    hostname = "inventree";
    stateVersion = "25.11";                       # set once, then leave
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
  caddy.enable = false;                # now http://<appAddress>:<port> is yours to proxy
  database.passwordFile = "/run/secrets/inventree-db";
};
```

## Secrets

Every secret is a **host path** to a file the module bind-mounts read-only into
the container and reads at service start — nothing is copied into the Nix store.
Wire them with agenix / sops-nix / plain files as you like; just make sure the
file exists before `container@<hostname>.service` starts.

| option | required | contents |
|---|---|---|
| `database.passwordFile` | yes | PostgreSQL password for `database.user` |
| `smtp.passwordFile` | when `smtp.host` is set | SMTP password |
| `tailscale.authKeyFile` | no | Tailscale auth key for non-interactive join |

## Versions & upgrades

`version` is an enum over the `<tag>/` directories in this repo. All supported
tags share one topology, one `postgres:13`, and one data directory, so raising
`version` is an **in-place upgrade**: the new image points at the existing
database and the container's `preStart` runs `invoke migrate` on every start.
**Downgrades are not supported.** Add a release by dropping in a new `<tag>/`
directory with its `default.nix`, `docker-compose.yml` and `nginx.prod.conf`.

### Known upgrade gotcha: 0.11 → 0.12/0.13

The first migration to 0.12+ (`part.0109_auto_20230517_1048`) calls into the
unit registry, which queries the `common_customunit` table — but Django orders
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
