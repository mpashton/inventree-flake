{ config, lib, ... }:

let
  cfg = config.services.containers.inventree;

  inventree = {
    # Path *inside* the nspawn container that becomes INVENTREE_EXT_VOLUME.
    # This is where the postgres cluster, media, static files and secret key all live
    # (the selected version's compose file maps ALL of it from a single bind-mounted volume).
    dataDir = "/var/lib/inventree/data";
    composeDir = "/etc/inventree-docker";

    # Where the secret files supplied via *File options are bind-mounted, read-only.
    secretsDir = "/run/inventree";
  };

  # ---------------------------------------------------------------------------
  # Version registry - auto-discovered from the per-version subdirectories.
  # ---------------------------------------------------------------------------
  # Each <tag>/ directory next to this file is one supported InvenTree release.
  # It supplies its own default.nix - { tag; dockerComposeYml; nginxProdConf;
  # extraEnv ? ""; } - alongside that tag's verbatim upstream docker-compose.yml
  # and nginx.prod.conf. To add a rung, drop in a new <tag>/ directory; nothing
  # in this file changes.
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

  # Non-secret half of upstream's docker/production/.env. The DB and SMTP
  # passwords are appended at service-start time from the bind-mounted secret
  # files - never baked into the store.
  envTemplate = pkgs: pkgs.writeText "inventree.env" (''
    INVENTREE_EXT_VOLUME=${inventree.dataDir}
    INVENTREE_WEB_PORT=${toString cfg.port}
    INVENTREE_DEBUG=False
    INVENTREE_LOG_LEVEL=WARNING
    INVENTREE_DB_ENGINE=postgresql
    INVENTREE_DB_NAME=${cfg.database.name}
    INVENTREE_DB_HOST=inventree-db
    INVENTREE_DB_PORT=5432
    INVENTREE_DB_USER=${cfg.database.user}
    INVENTREE_GUNICORN_TIMEOUT=30
    INVENTREE_PLUGINS_ENABLED=False
    INVENTREE_TAG=${cfg.version}
    COMPOSE_PROJECT_NAME=${cfg.composeProjectName}
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
in
{
  options.services.containers.inventree = {
    enable = lib.mkEnableOption ''
      a legacy InvenTree instance (releases 0.11-0.13, the pre-0.14 nginx
      reverse-proxy generation) running its upstream production docker-compose
      stack inside a systemd-nspawn container
    '';

    version = lib.mkOption {
      type = lib.types.enum (lib.attrNames versions);
      default = "0.13.6";
      description = ''
        Which InvenTree release to run. Only the pre-0.14 (nginx reverse proxy)
        generation is offered. Raising this is an in-place upgrade against the
        shared {option}`services.containers.inventree.dataDir` database - schema migrations
        run automatically on every start. Downgrades are not supported. Every
        offered release is years past upstream security support and must stay
        off the public internet.
      '';
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "inventree";
      description = ''
        Hostname of the InvenTree container. Also used as the nspawn container
        name (hence the name of the generated `container@<name>.service`) and as
        the default {option}`services.containers.inventree.virtualHost`.
      '';
    };

    stateVersion = lib.mkOption {
      type = lib.types.str;
      default = "25.11";
      description = ''
        `system.stateVersion` for the container's own NixOS instance. Set this
        once, when the container is first created, and leave it.
      '';
    };

    virtualHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.containers.inventree.hostname";
      description = ''
        Host the bundled Caddy serves the InvenTree UI on, inside the container.
        Set this to the fully-qualified name it should answer to (e.g. the
        `<hostname>.<tailnet>.ts.net` MagicDNS name); it defaults to the bare
        container hostname. Ignored when {option}`services.containers.inventree.caddy.enable`
        is false.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1337;
      description = ''
        TCP port the InvenTree stack's own nginx proxy publishes on the
        container. The bundled Caddy reverse-proxies to it; if you set
        {option}`services.containers.inventree.caddy.enable` to false, point your own proxy
        at `http://<appAddress>:<port>`.
      '';
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.2";
      description = ''
        IPv4 address of the host side of the container's private veth link (the
        outer machine's end of the point-to-point pair).
      '';
    };

    appAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.3";
      description = ''
        IPv4 address assigned to the InvenTree container on its private veth link
        (the container's own end of the point-to-point pair).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/inventree/data";
      description = ''
        Host directory holding InvenTree's single external volume: the postgres
        cluster, media, static files and Django secret key. Bind-mounted into the
        container. Switching {option}`services.containers.inventree.version` migrates this
        database in place, so keep it stable across upgrades.
      '';
    };

    dockerDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/inventree/docker";
      description = ''
        Host directory backing the container's own `/var/lib/docker`, kept
        separate from {option}`services.containers.inventree.dataDir` so images and layers
        can be discarded without touching the database.
      '';
    };

    composeProjectName = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.containers.inventree.hostname";
      description = ''
        `COMPOSE_PROJECT_NAME` for the stack. Only a label - but it names the
        docker resources, so changing it on a running instance orphans the old
        containers. Pin it if you rename the host.
      '';
    };

    enableGoogleLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Load django-allauth's Google provider. The OAuth client ID/secret are
        *not* configured here - they live in the database as a SocialApp row
        (Django Admin -> Sites -> Social Applications), which comes along with any
        database restore from an instance that already had Google login set up.
        This flag only controls whether InvenTree loads the provider app at all.
      '';
    };

    database = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "inventree";
        description = "PostgreSQL database name (`INVENTREE_DB_NAME`).";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "inventree";
        description = ''
          PostgreSQL role the stack connects as (`INVENTREE_DB_USER`). The
          bundled postgres container creates this role on first run; for an
          existing database it must match the role that already owns it.
        '';
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Host path to a file containing the PostgreSQL password. Bind-mounted
          read-only into the container and read at service start - never copied
          into the store. Required when the module is enabled. Wire this to
          agenix/sops/etc. yourself; make sure the file exists before
          `container@${cfg.hostname}.service` starts.
        '';
      };
    };

    tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run Tailscale inside the container. This is the module's intended
          exposure model: the InvenTree UI is reached over the tailnet and the
          bundled Caddy obtains its TLS certificate with `tailscale cert`. Turn
          this off only if you are fronting the container with your own
          networking, in which case also set
          {option}`services.containers.inventree.caddy.enable` to false.
        '';
      };
      authKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Host path to a file containing a Tailscale auth key, used to bring the
          container onto the tailnet non-interactively. Bind-mounted read-only.
          When null, run `tailscale up` inside the container by hand once.
        '';
      };
    };

    caddy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Front InvenTree with Caddy inside the container, serving
        {option}`services.containers.inventree.virtualHost` with a Tailscale-issued
        certificate. Requires {option}`services.containers.inventree.tailscale.enable`.
        Disable to expose `http://<appAddress>:<port>` for your own proxy.
      '';
    };

    smtp = lib.mkOption {
      description = ''
        Outbound mail (password resets, notifications) via SMTP. Leave `host`
        blank to disable email entirely.
      '';
      default = { };
      type = lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "SMTP host. Blank disables outbound email.";
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
          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Host path to a file containing the SMTP password. Bind-mounted
              read-only into the container. Required when `host` is set.
            '';
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.passwordFile != null;
        message = "services.containers.inventree.database.passwordFile must be set when services.containers.inventree.enable is true.";
      }
      {
        assertion = cfg.smtp.host != "" -> cfg.smtp.passwordFile != null;
        message = "services.containers.inventree.smtp.passwordFile must be set when services.containers.inventree.smtp.host is non-empty.";
      }
      {
        assertion = !(cfg.smtp.useTls && cfg.smtp.useSsl);
        message = "services.containers.inventree.smtp: useTls and useSsl are mutually exclusive.";
      }
      {
        assertion = cfg.caddy.enable -> cfg.tailscale.enable;
        message = "services.containers.inventree.caddy.enable requires services.containers.inventree.tailscale.enable (the bundled Caddy serves virtualHost with a Tailscale certificate). Disable caddy to front the container with your own proxy.";
      }
    ];

    systemd.tmpfiles.rules = [
      # Wide open: the postgres/inventree images use their own internal UIDs which don't map
      # to anything on the host, and it isn't worth chasing exact numbers here.
      # Tighten later if it bothers you.
      "d ${cfg.dataDir} 0777 root root -"
      "d ${cfg.dockerDir} 0711 root root -"
    ];

    containers.${cfg.hostname} = {
      privateNetwork = true;
      hostAddress = cfg.hostAddress;
      localAddress = cfg.appAddress;
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

      bindMounts = {
        ${inventree.dataDir} = {
          isReadOnly = false;
          hostPath = cfg.dataDir;
        };
        # Give Docker's own storage a persistent home separate from the InvenTree data volume,
        # so you can blow away images/layers without touching the database.
        "/var/lib/docker" = {
          isReadOnly = false;
          hostPath = cfg.dockerDir;
        };
        "${inventree.secretsDir}/db-password" = {
          isReadOnly = true;
          hostPath = toString cfg.database.passwordFile;
        };
      }
      // lib.optionalAttrs (cfg.smtp.passwordFile != null) {
        "${inventree.secretsDir}/smtp-password" = {
          isReadOnly = true;
          hostPath = toString cfg.smtp.passwordFile;
        };
      }
      // lib.optionalAttrs (cfg.tailscale.authKeyFile != null) {
        "${inventree.secretsDir}/ts-authkey" = {
          isReadOnly = true;
          hostPath = toString cfg.tailscale.authKeyFile;
        };
      };

      config = { config, pkgs, lib, ... }: {
        system.stateVersion = cfg.stateVersion;

        networking = {
          hostName = cfg.hostname;
          # This relies on the private container bridge not being reachable off-box, and -
          # with the default tailscale.enable - on the instance only being published to the
          # tailnet. Never add a public vhost / ACME: every release this module runs is years
          # out of security patches. If you set tailscale.enable = false, it is on you to
          # restrict who can reach ${cfg.appAddress} on the host.
          firewall.enable = false;
          useHostResolvConf = lib.mkForce false;
        };

        services.resolved.enable = true;

        services.tailscale = lib.mkIf cfg.tailscale.enable {
          enable = true;
          authKeyFile = lib.mkIf (cfg.tailscale.authKeyFile != null)
            "${inventree.secretsDir}/ts-authkey";
          disableTaildrop = true;
          permitCertUid = lib.mkIf cfg.caddy.enable "caddy";
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
            echo "INVENTREE_DB_PASSWORD=$(cat ${inventree.secretsDir}/db-password)" \
              >> ${inventree.composeDir}/.env
          '' + lib.optionalString (cfg.smtp.host != "") ''
            echo "INVENTREE_EMAIL_PASSWORD=$(cat ${inventree.secretsDir}/smtp-password)" \
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

        services.caddy = lib.mkIf cfg.caddy.enable {
          enable = true;
          virtualHosts.${cfg.virtualHost} = {
            extraConfig = ''
              reverse_proxy http://localhost:${toString cfg.port}
            '';
          };
        };

        environment.systemPackages =
          lib.optional cfg.tailscale.enable pkgs.tailscale
          ++ [ pkgs.docker-compose ];
      };
    };
  };
}
