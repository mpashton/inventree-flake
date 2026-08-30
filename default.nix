{ inputs, ... }:
{
flake.modules.nixos.inventree = { config, lib, ... }:
let
  cfg = config.services.inventree;
  inventree = {
    # Path *inside* the nspawn container that becomes INVENTREE_EXT_VOLUME.
    # This is where the postgres cluster, media, static files and secret key all live
    # (the selected version's compose file maps ALL of it from a single bind-mounted volume).
    dataDir = "/var/lib/inventree/data";
    composeDir = "/etc/inventree-docker";

    # Host-side (outer machine) paths, bind-mounted into the container.
    hostDataDir = "/srv/inventree/data";
    hostDockerDir = "/srv/inventree/docker"; # backs the container's own /var/lib/docker

    containerName = cfg.hostname;
    virtualHost = "${cfg.hostname}.tail9afd.ts.net"; # adjust to your tailnet
    hostAddress = cfg.hostAddress;
    appAddress = cfg.appAddress;

    inventreeTag = cfg.version; # image tag == chosen version (see services.inventree.version)
    webPort = 1337; # matches upstream's INVENTREE_WEB_PORT default

    dbName = "inventree";
    dbUser = "pguser"; # not secret; only the password goes through agenix

    secretsDir = "../../machine/bingen2/secrets";
  };

  # ---------------------------------------------------------------------------
  # Version registry - auto-discovered from the per-version subdirectories.
  # ---------------------------------------------------------------------------
  # Each lib/inventree/<tag>/ directory is one supported InvenTree release. It
  # supplies its own default.nix - { tag; dockerComposeYml; nginxProdConf;
  # extraEnv ? ""; } - alongside that tag's verbatim upstream
  # docker-compose.yml and nginx.prod.conf. To add a rung, drop in a new
  # <tag>/ directory; nothing in this file changes.
  #
  # Only the pre-0.14 "nginx reverse proxy" generation fits this shape. 0.14
  # moved the compose file to docker/docker-compose.yml and swapped the bundled
  # nginx proxy for Caddy, which would need a second, incompatible topology
  # (different proxy image, different config file, no nginx.prod.conf).
  versions = lib.mapAttrs
    (name: _: import (./. + "/${name}"))
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./.));

  selected = versions.${cfg.version};
  dockerComposeYml = selected.dockerComposeYml;
  nginxProdConf = selected.nginxProdConf;

  # Non-secret half of upstream's docker/production/.env. INVENTREE_DB_PASSWORD is appended
  # at service-start time from the agenix secret - never baked into the store.
  envTemplate = pkgs: pkgs.writeText "inventree.env" (''
    INVENTREE_EXT_VOLUME=${inventree.dataDir}
    INVENTREE_WEB_PORT=${toString inventree.webPort}
    INVENTREE_DEBUG=False
    INVENTREE_LOG_LEVEL=WARNING
    INVENTREE_DB_ENGINE=postgresql
    INVENTREE_DB_NAME=${inventree.dbName}
    INVENTREE_DB_HOST=inventree-db
    INVENTREE_DB_PORT=5432
    INVENTREE_DB_USER=${inventree.dbUser}
    INVENTREE_GUNICORN_TIMEOUT=30
    INVENTREE_PLUGINS_ENABLED=False
    INVENTREE_TAG=${inventree.inventreeTag}
    COMPOSE_PROJECT_NAME=inventree-0-11-0
  '' + (selected.extraEnv or "") + lib.optionalString cfg.enableGoogleLogin ''
    INVENTREE_SOCIAL_BACKENDS=allauth.socialaccount.providers.google
  '' + lib.optionalString (cfg.smtp.host != "") ''
    INVENTREE_EMAIL_HOST=${cfg.smtp.host}
    INVENTREE_EMAIL_PORT=${toString cfg.smtp.port}
    INVENTREE_EMAIL_USERNAME=${cfg.smtp.username}
    INVENTREE_EMAIL_SENDER=${cfg.smtp.sender}
    INVENTREE_EMAIL_TLS=${if cfg.smtp.useTls then "True" else "False"}
    INVENTREE_EMAIL_SSL=${if cfg.smtp.useSsl then "True" else "False"}
  '');

in {
  options.services.inventree = {
    version = lib.mkOption {
      type = lib.types.enum (lib.attrNames versions);
      default = "0.13.6";
      description = ''
        Which InvenTree release to run. Only the pre-0.14 (nginx reverse
        proxy) generation is offered. Raising this is an in-place upgrade
        against the shared ${inventree.hostDataDir} database - schema
        migrations run automatically on every start. Downgrades are not
        supported. Every offered release is years past upstream security
        support and must stay reachable only over Tailscale.
      '';
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      default = "inventree0110";
      description = ''
        Hostname of the InvenTree container. Also used for the nspawn container
        name and the "<hostname>.tail9afd.ts.net" Tailscale virtual host that
        Caddy serves.
      '';
    };
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.2";
      description = ''
        IPv4 address of the host side of the InvenTree container's private
        veth link (the outer machine's end of the point-to-point pair).
      '';
    };
    appAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.3";
      description = ''
        IPv4 address assigned to the InvenTree container on its private
        veth link (the container's own end of the point-to-point pair).
      '';
    };
    enableGoogleLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the "Sign in with Google" backend. The actual OAuth client
        ID/secret are *not* configured here - they live in the database as a
        django-allauth SocialApp row (Django Admin -> Sites -> Social
        Applications), which comes along for free with any database restore
        from an instance that already had Google login set up the same way.
        This flag only controls whether InvenTree loads the google provider
        app at all.
      '';
    };
    smtp = lib.mkOption {
      description = ''
        Outbound mail (password resets, notifications) via SMTP. Leave
        `host` blank to disable email entirely. The password is supplied
        separately via agenix (secrets/inventree0110-smtp-password.age).
      '';
      default = {};
      type = lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "SMTP host.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 587;
            description = "SMTP port.";
          };
          username = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "SMTP auth username.";
          };
          sender = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "From: address for outbound mail.";
          };
          useTls = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Use STARTTLS.";
          };
          useSsl = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Use implicit TLS/SSL (mutually exclusive with useTls).";
          };
        };
      };
    };
  };

  config = {
  systemd.tmpfiles.rules = [
    # Wide open: the postgres/inventree images use their own internal UIDs which don't map
    # to anything on the host, and it isn't worth chasing exact numbers for a migration rung.
    # Tighten later if it bothers you.
    "d ${inventree.hostDataDir} 0777 root root -"
    "d ${inventree.hostDockerDir} 0711 root root -"
  ];

  containers.${inventree.containerName} = {
    privateNetwork = true;
    hostAddress = inventree.hostAddress;
    localAddress = inventree.appAddress;
    ephemeral = false;
    autoStart = true;
    enableTun = true;

    # The outer container@<name>.service only reports "active" once the inner systemd
    # reaches multi-user.target, which waits on inventree-compose's preStart (first-run
    # `invoke migrate`/`invoke static` can take several minutes). The default 1min timeout
    # kills and restarts the whole container mid-migration, forever - give it real headroom.
    timeoutStartSec = "15min";

    # Docker needs more from the container than nspawn grants by default: it wants to manage
    # its own cgroups/netns/overlayfs, which conflicts with nspawn's own user-namespace
    # remapping if that's left on, and needs capabilities nspawn's default profile omits.
    privateUsers = "no";
    additionalCapabilities = [
      "CAP_SYS_ADMIN"
      "CAP_NET_ADMIN"
      "CAP_MKNOD"
      "CAP_AUDIT_WRITE"
      "CAP_SYS_RESOURCE"
      "CAP_NET_RAW"
    ];
    # nspawn's default seccomp filter blocks bpf(2), which runc needs to attach the
    # cgroup-device BPF program when starting a container. Without this, dockerd fails
    # every container start with "bpf_prog_query(BPF_CGROUP_DEVICE) failed: operation
    # not permitted", even though CAP_SYS_ADMIN is already granted above.
    extraFlags = [ "--system-call-filter=bpf" ];

    bindMounts."/etc/ssh/ssh_host_ed25519_key".isReadOnly = true;
    bindMounts.${inventree.dataDir} = {
      isReadOnly = false;
      hostPath = inventree.hostDataDir;
    };
    # Give Docker's own storage a persistent home separate from the InvenTree data volume,
    # so you can blow away images/layers without touching the database.
    bindMounts."/var/lib/docker" = {
      isReadOnly = false;
      hostPath = inventree.hostDockerDir;
    };

    config = { config, pkgs, lib, ... }: {
      imports = [ inputs.agenix.nixosModules.default ];

      system.stateVersion = "25.05";

      networking = {
        hostName = cfg.hostname;
        # Matches your snipe-it module's posture: this relies on the private container
        # bridge not being reachable off-box. Never add a public vhost/ACME for this instance -
        # every version this module offers is years out of security patches and should only
        # ever be reachable via Tailscale.
        firewall.enable = false;
        useHostResolvConf = lib.mkForce false;
      };

      services.resolved.enable = true;

      age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      age.secrets."inventree0110-tsauth" = {
        file = ./${inventree.secretsDir}/inventree0110-tsauth.age;
        mode = "400";
      };
      age.secrets."inventree-db-password" = {
        file = ./${inventree.secretsDir}/inventree-db-password.age;
        mode = "400";
      };
      age.secrets."inventree0110-smtp-password" = lib.mkIf (cfg.smtp.host != "") {
        file = ./${inventree.secretsDir}/inventree0110-smtp-password.age;
        mode = "400";
      };

      services.tailscale = {
        enable = true;
        # authKeyFile = config.age.secrets."inventree0110-tsauth".path;
        disableTaildrop = true;
        permitCertUid = "caddy";
      };

      virtualisation.docker = {
        enable = true;
        # If this errors on your kernel/host fs combination, fall back to "vfs" (slower,
        # but always works nested inside another filesystem).
        storageDriver = "overlay2";
      };

      environment.etc."inventree-docker/docker-compose.yml".text = dockerComposeYml;
      environment.etc."inventree-docker/nginx.prod.conf".text = nginxProdConf;

      systemd.services.inventree-compose = {
        description = "InvenTree ${cfg.version} docker-compose stack";
        after = [ "docker.service" "network-online.target" ];
        wants = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];

        path = [ pkgs.docker-compose pkgs.docker ];

        # Render the real .env next to the (nix-managed, read-only) compose file. It's a
        # plain file outside the store, mode 600, recreated fresh on every start.
        #
        # InvenTree's docker image does *not* run migrations on its own - docker/init.sh
        # (the image ENTRYPOINT) only creates directories/config and then execs straight into
        # gunicorn. Upstream's docs call for a one-time `invoke update` before the stack can
        # serve anything; we run its `migrate` and `static` subtasks directly (idempotent -
        # safe on every start) rather than `update` itself, since `update` also runs `invoke
        # install` (`pip install -U -r requirements.txt` against live PyPI on every boot -
        # slow, and risks drifting package versions on a tag we deliberately pinned).
        # We wait for postgres to actually accept connections first, since `depends_on` only
        # waits for the container to start, not for it to be ready.
        preStart = ''
          set -o errexit
          install -m 600 ${envTemplate pkgs} ${inventree.composeDir}/.env
          echo "INVENTREE_DB_PASSWORD=$(cat ${config.age.secrets."inventree-db-password".path})" \
            >> ${inventree.composeDir}/.env
        '' + lib.optionalString (cfg.smtp.host != "") ''
          echo "INVENTREE_EMAIL_PASSWORD=$(cat ${config.age.secrets."inventree0110-smtp-password".path})" \
            >> ${inventree.composeDir}/.env
        '' + ''

          # A version switch renames the containers (0.13+ dropped the fixed
          # container_name:), so the previous stack can still be up against the
          # same data volume. Tear down whatever is running before starting the
          # selected version - all persistent state is in the bind-mounted data
          # dir, not the containers.
          docker-compose -f docker-compose.yml down --remove-orphans || true
          docker rm -f inventree-db inventree-cache inventree-server inventree-worker inventree-proxy 2>/dev/null || true

          docker-compose -f docker-compose.yml up -d inventree-db
          docker-compose -f docker-compose.yml run --rm inventree-server invoke wait
          docker-compose -f docker-compose.yml run --rm inventree-server invoke migrate
          docker-compose -f docker-compose.yml run --rm inventree-server invoke static
        '';

        serviceConfig = {
          Type = "simple";
          WorkingDirectory = inventree.composeDir;
          ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f docker-compose.yml up --remove-orphans";
          ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f docker-compose.yml down";
          ExecStopPost = "${pkgs.coreutils}/bin/shred -u ${inventree.composeDir}/.env";
          Restart = "on-failure";
          RestartSec = 10;
          # First-run migrations (full schema + rebuild_models/rebuild_thumbnails +
          # collectstatic) can comfortably outrun systemd's 90s default.
          TimeoutStartSec = 600;
        };
      };

      services.caddy = {
        enable = true;
        virtualHosts.${inventree.virtualHost} = {
          extraConfig = ''
            reverse_proxy http://localhost:${toString inventree.webPort}
          '';
        };
      };

      environment.systemPackages = [ pkgs.tailscale pkgs.docker-compose ];
    };
  };
  };
};
}