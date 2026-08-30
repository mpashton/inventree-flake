# inventree-legacy-container

A NixOS module that runs a **legacy InvenTree** instance (releases **0.11 -
0.17**) from its upstream production `docker-compose` stack, inside a
`systemd-nspawn` container, reachable over Tailscale.

## ⚠️ Security

These InvenTree releases are **past upstream security support**. This module is
for keeping an old instance alive on an internal network while you plan the jump
to a current release - not for a fresh deployment.

By default the instance is published **only to your tailnet**. The container
turns its own firewall off and relies on the private veth link not being
routable off-box. **Do not add a public virtual host or ACME.** If you set
`tailscale.enable = false`, restricting access to the container becomes your
responsibility.

## What it builds

A single nspawn container running upstream's production compose stack verbatim
for the chosen tag:

- PostgreSQL 13 (every supported version)
- gunicorn (InvenTree web server)
- django-q (background worker)
- the stack's own reverse proxy / static+media server

plus, in the container, Docker itself and Tailscale. All InvenTree state
(database, media, static, secret key) lives in one host directory (`dataDir`)
bind-mounted in as `INVENTREE_EXT_VOLUME`.

### Two proxy generations

| versions | stack proxy | how the tailnet sees it |
|---|---|---|
| **0.11 - 0.13** | bundled **nginx** on `:80` | the module runs its own NixOS **Caddy** in front, terminating TLS for `virtualHost` with a `tailscale cert` |
| **0.14 - 0.17** | bundled **Caddy** | it faces the tailnet **directly**, serving `siteUrl` and fetching the `*.ts.net` certificate straight from the container's `tailscaled` |

**0.17.14 is the last release before the 1.0 rewrite** - reach it, verify the
instance, and back up `dataDir` before attempting 1.x (not covered here).

The per-tag `docker-compose.yml` and proxy config (`nginx.prod.conf` or
`Caddyfile`) under each `<tag>/` directory are copied **verbatim** from
`https://github.com/inventree/InvenTree/tree/<tag>/`. The 0.14+ dirs add one
non-upstream file, `docker-compose.override.yml`, which bind-mounts
`tailscaled.sock` into the proxy container so Caddy can fetch the certificate.

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
                             # 0.14-0.17: stack Caddy serves `siteUrl` plain, on :port.
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

`version` is an enum over the `<tag>/` directories. Every supported tag shares
one `postgres:13` and one data directory, so raising `version` is an **in-place
upgrade**: the new image points at the existing database and the container's
`preStart` runs `invoke migrate` on every start. **Downgrades are not
supported.**

Add a release by dropping in a new `<tag>/` directory whose `default.nix`
declares `proxy` (`"nginx"` / `"caddy"`) and reads its verbatim
`docker-compose.yml` + proxy config (plus, for the caddy generation,
`docker-compose.override.yml`). Nothing in `module.nix` changes.

### The 0.13 -> 0.14 step

This is where the proxy topology flips (nginx -> the stack's own Caddy). The
module handles the mechanics; nothing to do beyond the version bump. From
**0.16** on, `INVENTREE_SITE_URL` (set from the `siteUrl` option) must be correct
or the server refuses to start / login fails with a CSRF error - `siteUrl`
defaults to `https://<virtualHost>`, so just make sure `virtualHost` is the real
MagicDNS name.

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
