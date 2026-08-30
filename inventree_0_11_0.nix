{ inputs, ... }:
{
flake.modules.nixos.inventree-0-11-0 = { config, lib, ... }:
let
  cfg = config.services.inventree0110;
  inventree = {
    # Path *inside* the nspawn container that becomes INVENTREE_EXT_VOLUME.
    # This is where the postgres cluster, media, static files and secret key all live
    # (upstream's 0.11.0 compose file maps ALL of it from a single bind-mounted volume).
    dataDir = "/var/lib/inventree/data";
    composeDir = "/etc/inventree-docker";

    # Host-side (outer machine) paths, bind-mounted into the container.
    hostDataDir = "/srv/inventree/data";
    hostDockerDir = "/srv/inventree/docker"; # backs the container's own /var/lib/docker

    containerName = cfg.hostname;
    virtualHost = "${cfg.hostname}.tail9afd.ts.net"; # adjust to your tailnet
    hostAddress = cfg.hostAddress;
    appAddress = cfg.appAddress;

    inventreeTag = "0.11.0"; # pin deliberately - do NOT let this drift to "stable"
    webPort = 1337; # matches upstream's INVENTREE_WEB_PORT default

    dbName = "inventree";
    dbUser = "pguser"; # not secret; only the password goes through agenix

    secretsDir = "../../machine/bingen2/secrets";
  };

  # Verbatim from:
  # https://github.com/inventree/InvenTree/blob/0.11.0/docker/production/docker-compose.yml
  # When you move to the next rung, replace this whole string with that tag's file rather
  # than hand-editing it - env var names and topology both shift across versions.
  dockerComposeYml = ''
    version: "3.8"

    # Docker compose recipe for a production-ready InvenTree setup, with the following containers:
    # - PostgreSQL as the database backend
    # - gunicorn as the InvenTree web server
    # - django-q as the InvenTree background worker process
    # - nginx as a reverse proxy
    # - redis as the cache manager (optional, disabled by default)

    services:
        inventree-db:
            container_name: inventree-db
            image: postgres:13
            expose:
                - ''${INVENTREE_DB_PORT:-5432}/tcp
            environment:
                - PGDATA=/var/lib/postgresql/data/pgdb
                - POSTGRES_USER=''${INVENTREE_DB_USER:?You must provide the 'INVENTREE_DB_USER' variable in the .env file}
                - POSTGRES_PASSWORD=''${INVENTREE_DB_PASSWORD:?You must provide the 'INVENTREE_DB_PASSWORD' variable in the .env file}
                - POSTGRES_DB=''${INVENTREE_DB_NAME:?You must provide the 'INVENTREE_DB_NAME' variable in the .env file}
            volumes:
                - inventree_data:/var/lib/postgresql/data/
            restart: unless-stopped

        inventree-cache:
            container_name: inventree-cache
            image: redis:7.0
            depends_on:
                - inventree-db
            profiles:
                - redis
            env_file:
                - .env
            expose:
                - ''${INVENTREE_CACHE_PORT:-6379}
            restart: always

        inventree-server:
            container_name: inventree-server
            image: inventree/inventree:''${INVENTREE_TAG:-stable}
            expose:
                - 8000
            depends_on:
                - inventree-db
            env_file:
                - .env
            volumes:
                - inventree_data:/home/inventree/data
            restart: unless-stopped

        inventree-worker:
            container_name: inventree-worker
            image: inventree/inventree:''${INVENTREE_TAG:-stable}
            command: invoke worker
            depends_on:
                - inventree-server
            env_file:
                - .env
            volumes:
                - inventree_data:/home/inventree/data
            restart: unless-stopped

        inventree-proxy:
            container_name: inventree-proxy
            image: nginx:stable
            depends_on:
                - inventree-server
            env_file:
                - .env
            ports:
                - ''${INVENTREE_WEB_PORT:-1337}:80
            volumes:
                - ./nginx.prod.conf:/etc/nginx/conf.d/default.conf:ro
                - inventree_data:/var/www
            restart: unless-stopped

    volumes:
        inventree_data:
            driver: local
            driver_opts:
                type: none
                o: bind
                device: ''${INVENTREE_EXT_VOLUME:?You must specify the 'INVENTREE_EXT_VOLUME' variable in the .env file!}
  '';

  # Verbatim from:
  # https://github.com/inventree/InvenTree/blob/0.11.0/docker/production/nginx.prod.conf
  nginxProdConf = ''
    server {

        listen 80;

        real_ip_header proxy_protocol;

        location / {

            proxy_set_header      Host              $http_host;
            proxy_set_header      X-Forwarded-By    $server_addr:$server_port;
            proxy_set_header      X-Forwarded-For   $remote_addr;
            proxy_set_header      X-Forwarded-Proto $scheme;
            proxy_set_header      X-Real-IP         $remote_addr;
            proxy_set_header      CLIENT_IP         $remote_addr;

            proxy_pass_request_headers on;

            proxy_redirect off;

            client_max_body_size 100M;

            proxy_buffering off;
            proxy_request_buffering off;

            proxy_pass http://inventree-server:8000;
        }

        location /static/ {
            alias /var/www/static/;
            autoindex on;

            expires 30d;
            add_header Pragma public;
            add_header Cache-Control "public";
        }

        location /media/ {
            alias /var/www/media/;

            auth_request /auth;

            add_header Content-disposition "attachment";
        }

        location /auth {
            internal;

            proxy_pass http://inventree-server:8000/auth/;

            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Original-URI $request_uri;
        }

    }
  '';

  # Non-secret half of upstream's docker/production/.env. INVENTREE_DB_PASSWORD is appended
  # at service-start time from the agenix secret - never baked into the store.
  envTemplate = pkgs: pkgs.writeText "inventree0110.env" ''
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
  '';

in {
  options.services.inventree0110 = {
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
        # 0.11.0 is years out of security patches and should only ever be reachable via Tailscale.
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
        description = "InvenTree 0.11.0 docker-compose stack";
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