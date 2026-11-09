# Nix flake for InvenTree inventory management system
#
# - Uses the Inventree upstream Docker Compose
# - Allows selecting from a list of InvenTree releases
# - Optionally set up Caddy for recent versions, or nginx for a few very old versions
# - Automatically adapts to running in a ctrnet instance

{ config, lib, pkgs, options, ... }:

let
  cfg = config.services.inventree;

  # Detect whether we are running in `ctrnet`.
  containerised = options ? ctrnet;

  paths =
    if containerised then {
      # in-container mount points (the wrapper maps the host dirs onto these)
      extVolume = "/var/lib/inventree/data";
      dbPassword = "/run/inventree/db-password";
      smtpPassword = "/run/inventree/smtp-password";
    } else {
      extVolume = cfg.dataDir;
      dbPassword = toString cfg.database.passwordFile;
      smtpPassword = if cfg.smtp.passwordFile != null then toString cfg.smtp.passwordFile else null;
    };

  inventree = {
    composeDir = "/etc/inventree-docker";
  };

  # ---------------------------------------------------------------------------
  # Version registry - auto-discovered from the per-version subdirectories.
  # ---------------------------------------------------------------------------
  # Each <tag>/ directory next to this file is one supported InvenTree release,
  # supplying its own default.nix:
  #
  #   { tag; proxy;                       # "nginx" (<= 0.13) | "caddy" (>= 0.14)
  #     dockerComposeYml;                 # verbatim upstream
  #     proxyConfig = { file; text; };    # nginx.prod.conf / Caddyfile, verbatim
  #     extraEnv ? ""; }
  #
  # alongside those verbatim files. To add a rung, drop in a new <tag>/
  # directory; nothing in this file changes.
  #
  # Two proxy topologies are handled:
  #   - "nginx"  (0.11-0.13): the stack ships an nginx proxy on :80; this module
  #     fronts it with a NixOS Caddy for the tailnet TLS certificate.
  #   - "caddy"  (0.14 onward): the stack ships its own Caddy, which faces the
  #     tailnet directly and pulls the *.ts.net certificate from tailscaled
  #     (whichever system runs it) over the bind-mounted socket. No NixOS Caddy.
  # The 1.x series (a rewrite) keeps the caddy topology but renames some .env
  # vars and bumps postgres to 17 - see `isV1` below.
  versions = lib.mapAttrs
    (name: _: import (./. + "/version/${name}"))
    (lib.filterAttrs
      (name: t: t == "directory" && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" name != null)
      (builtins.readDir ./version));

  selected = versions.${cfg.version};
  dockerComposeYml = selected.dockerComposeYml;

  caddyGen = selected.proxy == "caddy";
  # 1.x renamed the proxy port vars, enables redis by default, and ships
  # postgres:17. `version` is a real release string, so a numeric compare is safe.
  isV1 = lib.versionAtLeast cfg.version "1.0.0";

  # True when the stack's TLS front is active and needs a tailnet cert.
  tlsFront = cfg.caddy.enable;

  # Plugins (`plugins`, an attrset of submodules). Each is either a
  # plugin derivation (`package`: `$out/<module>` + `passthru.inventreePlugin.module`,
  # see inventree-plugin.nix) or a dev directory (`path`). The custom plugin
  # directory is a store `linkFarm` with one symlink per entry, so the
  # containers need every link *target* visible at the same path - see
  # `pluginMounts`. Built tolerantly: a malformed entry (neither / both of
  # package and path) is reported by an assertion, not an evaluation error.
  pluginEntries = lib.mapAttrsToList
    (label: p:
      if p.package != null then
        let
          m = p.package.passthru.inventreePlugin.module or (throw
            "services.inventree.plugins.${label}: ${p.package.name} has no `passthru.inventreePlugin.module` - build it with inventree-flake's `lib.inventreePlugin`, or set that attribute and install the plugin to $out/<module>.");
        in
        { inherit label; name = m; target = "${p.package}/${m}"; mount = "${p.package}"; mountAt = "${p.package}"; dev = false; drv = p.package; inherit (p) slug active; }
      else if p.path != null then
        let at = "${devMountRoot}/${baseNameOf p.path}"; in
        { inherit label; name = baseNameOf p.path; target = at; mount = p.path; mountAt = at; dev = true; drv = null; inherit (p) slug active; }
      else
        { inherit label; name = label; target = "/nonexistent"; mount = "/nonexistent"; mountAt = "/nonexistent"; dev = true; drv = null; inherit (p) slug active; })
    cfg.plugins;

  # Where dev plugin directories (`path`) appear inside the containers.
  # Must stay out of /home: upstream's init.sh runs
  # `git config --global --add safe.directory /home/***` with the glob
  # unquoted, so a second entry under /home (e.g. /home/data from a dev path
  # mounted at its host path) makes git fail with "wrong number of arguments"
  # and the container exits before doing anything.
  devMountRoot = "/opt/inventree-dev-plugins";

  # Slugs force-activated through INVENTREE_PLUGINS_MANDATORY (1.x).
  activeSlugs = lib.concatMap (e: lib.optional (e.active && e.slug != null) e.slug) pluginEntries;

  # Plugin settings (`.env` lines). The user's `pluginConfigs` plus whatever each
  # packaged plugin declares in `passthru.inventreePlugin.pluginConfigs`, merged
  # per key. Keys are normalised to their `INVENTREE_` form and values to what
  # the env sees, so `ENABLE_PLUGINS_URL = true` and
  # `INVENTREE_ENABLE_PLUGINS_URL = "True"` are the same setting. Sources that
  # agree merge silently; sources that disagree are a `pluginConfigConflicts`
  # entry, reported by an assertion (until then the first source wins).
  normKey = k: if lib.hasPrefix "INVENTREE_" k then k else "INVENTREE_${k}";
  renderVal = v: if lib.isBool v then (if v then "True" else "False") else v;
  pluginConfigSources =
    lib.concatMap
      (e: lib.optionals (e.drv != null)
        (lib.mapAttrsToList
          (k: v: { key = normKey k; val = renderVal v; source = "plugin ${e.label}"; })
          (e.drv.passthru.inventreePlugin.pluginConfigs or { })))
      pluginEntries
    ++ lib.mapAttrsToList
      (k: v: { key = normKey k; val = renderVal v; source = "services.inventree.pluginConfigs"; })
      cfg.pluginConfigs;
  pluginConfigGroups = lib.groupBy (s: s.key) pluginConfigSources;
  pluginConfigConflicts = lib.filterAttrs
    (_: ss: lib.length (lib.unique (map (s: s.val) ss)) > 1)
    pluginConfigGroups;
  effectivePluginConfigs = lib.mapAttrs (_: ss: (lib.head ss).val) pluginConfigGroups;

  # InvenTree's registry (plugin/registry.py, plugin_dirs) writes an
  # `__init__.py` into the plugin directory when it is missing, and drops the
  # directory if that fails - which it always does on the read-only store. So
  # the linkFarm ships the marker file itself.
  pluginDirInit = pkgs.writeText "__init__.py" "# InvenTree plugin directory\n";

  pluginDir = pkgs.linkFarm "inventree-plugins"
    ([{ name = "__init__.py"; path = pluginDirInit; }]
      ++ map (e: { inherit (e) name; path = e.target; }) pluginEntries);

  # Read-only bind mounts so the symlinks resolve inside the containers: store
  # paths at identical paths, dev paths at `devMountRoot`.
  # `create_host_path: false`: a missing dev path must fail the start, not be
  # silently created as an empty root-owned directory.
  pluginMounts = lib.unique (
    map (p: { source = p; target = p; }) [ "${pluginDir}" "${pluginDirInit}" ]
    ++ map (e: { source = e.mount; target = e.mountAt; }) pluginEntries);

  # Compose override generated by the module (not upstream). Reasons it may
  # exist: pinning the postgres image (e.g. staying on :13 while upstream ships
  # :17), mounting the plugin directory and its link targets into the server and
  # worker, and - caddy generation with the TLS front on - mounting tailscaled's
  # socket into the proxy container so the bundled Caddy can fetch the cert.
  composeOverride =
    let
      pluginVolumes = lib.concatMap
        (m: [
          "      - type: bind"
          "        source: ${builtins.toJSON m.source}"
          "        target: ${builtins.toJSON m.target}"
          "        read_only: true"
          "        bind:"
          "          create_host_path: false"
        ])
        pluginMounts;
      lines =
        lib.optionals (cfg.database.image != null) [
          "  inventree-db:"
          "    image: ${cfg.database.image}"
        ]
        ++ lib.optionals (cfg.plugins != { }) (
          [ "  inventree-server:" "    volumes:" ] ++ pluginVolumes
          ++ [ "  inventree-worker:" "    volumes:" ] ++ pluginVolumes
        )
        ++ lib.optionals (caddyGen && tlsFront) [
          "  inventree-proxy:"
          "    volumes:"
          "      - ${cfg.tailscaleSocket}:/var/run/tailscale/tailscaled.sock"
        ];
    in
    if lines == [ ] then null
    else lib.concatStringsSep "\n" ([
      "# Generated by the inventree NixOS module (not from upstream)."
      "services:"
    ] ++ lines) + "\n";

  composeFileArgs = "-f docker-compose.yml"
    + lib.optionalString (composeOverride != null) " -f docker-compose.override.yml";

  # nginx gen: the stack's proxy is published here and the NixOS Caddy (or the
  # user's own) reverse-proxies to it. caddy gen: the stack's Caddy is the front
  # door, so it takes :80 directly (and :443 from the upstream compose) unless
  # something else is running in front (caddy.enable = false).
  webPort = if caddyGen && tlsFront then 80 else cfg.port;

  # Non-secret half of upstream's docker/production/.env. The DB and SMTP
  # passwords are appended at service-start time from their files - never baked
  # into the store.
  envTemplate = pkgs.writeText "inventree.env" (''
    INVENTREE_EXT_VOLUME=${paths.extVolume}
    INVENTREE_DEBUG=False
    INVENTREE_LOG_LEVEL=WARNING
    INVENTREE_DB_ENGINE=postgresql
    INVENTREE_DB_NAME=${cfg.database.name}
    INVENTREE_DB_HOST=inventree-db
    INVENTREE_DB_PORT=5432
    INVENTREE_DB_USER=${cfg.database.user}
    INVENTREE_GUNICORN_TIMEOUT=30
    INVENTREE_PLUGINS_ENABLED=${if cfg.enablePlugins then "True" else "False"}
    INVENTREE_TAG=${cfg.version}
    COMPOSE_PROJECT_NAME=${cfg.composeProjectName}
    INVENTREE_CORS_ORIGIN_ALLOW_ALL=${if cfg.cors.allowAll then "True" else "False"}
  '' + lib.optionalString (cfg.cors.whitelist != [ ]) ''
    INVENTREE_CORS_ORIGIN_WHITELIST=${lib.concatStringsSep "," cfg.cors.whitelist}
  '' + lib.optionalString (!isV1) ''
    INVENTREE_WEB_PORT=${toString webPort}
  '' + lib.optionalString caddyGen ''
    INVENTREE_SITE_URL=${cfg.siteUrl}
    INVENTREE_USE_X_FORWARDED_HOST=True
    INVENTREE_USE_X_FORWARDED_PORT=True
    INVENTREE_USE_X_FORWARDED_PROTO=True
    INVENTREE_AUTO_UPDATE=False
  '' + lib.optionalString isV1 ''
    INVENTREE_WEB_PORT=8000
    INVENTREE_HTTP_PORT=${toString webPort}
    INVENTREE_HTTPS_PORT=443
    INVENTREE_CACHE_ENABLED=True
    INVENTREE_CACHE_HOST=inventree-cache
    INVENTREE_CACHE_PORT=6379
  '' + (selected.extraEnv or "") + lib.optionalString (cfg.plugins != { }) ''
    INVENTREE_PLUGIN_DIR=${pluginDir}
  '' + lib.optionalString (activeSlugs != [ ]) ''
    INVENTREE_PLUGINS_MANDATORY=${lib.concatStringsSep "," activeSlugs}
  '' + lib.concatStrings (lib.mapAttrsToList
    (k: v: "${k}=${v}\n")
    effectivePluginConfigs)
  + lib.optionalString cfg.enableGoogleLogin ''
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
  # This module declares `services.inventree` itself; nixpkgs' own module of
  # that name would otherwise collide with it (same option paths).
  disabledModules = [ "services/misc/inventree.nix" ];

  options.services.inventree = {
    enable = lib.mkEnableOption ''Whether to enable InvenTree.'';

    version = lib.mkOption {
      type = lib.types.enum (lib.attrNames versions);
      default = "0.17.14";
      description = ''InvenTree release to be installed.  Must be one of the directory names under `version/`.

        Inventree does not support downgrades, so be sure to make a backup before changing this.'';
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "inventree";
      description = ''Hostname for the site, without domain.'';
    };

    virtualHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.inventree.hostname";
      description = ''Virtual hostname for the site.
      '';
    };

    siteUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.virtualHost}";
      defaultText = lib.literalExpression ''"https://" + config.services.inventree.virtualHost'';
      description = ''Virtual URL for the site.  Normally no need to change this.
      '';
    };

    cors = {
      allowAll = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''See `INVENTREE_CORS_ORIGIN_ALLOW_ALL`.  Normally false, except in certain development situations.
        '';
      };

      whitelist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "https://dashboard.example.com" ];
        description = ''See `INVENTREE_CORS_ORIGIN_WHITELIST`.  If your site has a second URL, you may need to add it here.
        '';
      };
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1337;
      description = ''InvenTree internal HTTP port.  Normally claimed by the reverse proxy.  Only needed with a custom reverse proxy.'';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/inventree/data";
      description = ''Inventree data directory on the target host.'';
    };

    composeProjectName = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.inventree.hostname";
      description = ''`COMPOSE_PROJECT_NAME`.  Normally the hostname.  Do not change this unless you know what you're doing.'';
    };

    tailscaleSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/tailscale/tailscaled.sock";
      description = ''For Caddy installations with Tailscale, this is the Tailscale socket file which Caddy should use to set up TLS.'';
    };

    enableGoogleLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''Whether to enable Google logins.'';
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ config, name, ... }: {
        options = {
          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default =
              if config.path != null
              then null
              else (pkgs.inventreePlugins or { }).${name} or null;
            defaultText = lib.literalExpression "pkgs.inventreePlugins.<name> if the in-tree collection has one and `path` is unset, else null";
            example = lib.literalExpression "pkgs.inventreePlugins.ipn-generator";
            description = ''inventree-flake plugin derivation.  Use this option to install a plugin from a flake.

              Only one of `path` and `package` may be set.
            '';
          };

          path = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "/.+");
            default = null;
            example = "/home/me/src/my-plugin/my_plugin";
            description = ''
              Directory containing a plugin.  This must be on the taregt host, as it will be 
              bind-mounted to the Docker.  It does not have to be a flake.
            
              Only one of `path` and `package` may be set.
            '';
          };

          slug = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default =
              if config.package != null
              then config.package.passthru.inventreePlugin.slug or null
              else null;
            defaultText = lib.literalExpression "package.passthru.inventreePlugin.slug (null for a path)";
            example = "ipngen";
            description = ''A short name used for plugin activation.  Required for `path` plugins.'';
          };

          active = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''Activate the plugin.  There will not be an option to
              deactivate it in the UI.  Works only for versions 1.0 and later.
            '';
          };
        };
      }));
      default = { };
      example = lib.literalExpression ''
        {
          ipn-generator.package = pkgs.inventreePlugins.ipn-generator;   # in-tree collection
          foo.package = inputs.my-plugin.packages.''${system}.default;    # a plugin flake
          wip = { path = "/home/me/src/wip/wip_plugin"; slug = "wip"; active = false; };  # development
        }
      '';
      description = ''
        InvenTree plugins, keyed by an arbitrary label, all installed into
        InvenTree's custom plugin directory (`INVENTREE_PLUGIN_DIR`). That
        directory is a Nix store `linkFarm` with one symlink per entry; the
        link targets are bind-mounted read-only, at the same paths, into the
        server and worker containers. Nothing is installed with pip and
        nothing is written to {option}`services.inventree.dataDir`.

        Being an attribute set, one module can add a plugin and another can
        adjust it - plugin flakes typically ship a `nixosModules.default` that
        sets `plugins.<name>.package`, and the
        host can then set `plugins.<name>.active = false`.

        Plugins can only import what the InvenTree image already ships - there
        is no dependency resolution. Installed plugins are registered
        **inactive** unless `active` (the default) force-activates them.
        Removing an entry does not delete its database row.

        Third-party plugin code runs inside the InvenTree server and worker
        containers with full access to the instance.
      '';
    };

    enablePlugins = lib.mkOption {
      type = lib.types.bool;
      default = cfg.plugins != { };
      defaultText = lib.literalExpression "config.services.inventree.plugins != { }";
      description = ''
        If true, enable the Inventree plugin system.  Defaults to true if 
        the plugins list is not empty.
      '';
    };

    pluginDir = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      readOnly = true;
      internal = true;
      default = if cfg.plugins == { } then null else pluginDir;
      defaultText = lib.literalExpression "linkFarm of plugins (null when empty)";
      description = "The generated custom plugin directory (a store path of symlinks).";
    };

    pluginConfigs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.bool);
      default = { };
      example = { ENABLE_PLUGINS_URL = true; ENABLE_PLUGINS_APP = true; };
      description = ''
        Extra plugin-related settings appended to the generated `.env` as
        `INVENTREE_<KEY>=<value>` lines (a key already starting `INVENTREE_` is
        left as-is; booleans render `True`/`False`). Use it for the per-feature
        master switches some plugins need - `ENABLE_PLUGINS_URL`,
        `ENABLE_PLUGINS_NAVIGATION`, `ENABLE_PLUGINS_APP`,
        `ENABLE_PLUGINS_SCHEDULE`, `ENABLE_PLUGINS_EVENTS`,
        `ENABLE_PLUGINS_INTERFACE`, `ENABLE_PLUGINS_MAILS` - or any other
        `INVENTREE_*` plugin option. A plugin that adds database models
        (`ENABLE_PLUGINS_APP`) needs to be active before `invoke migrate` runs,
        so its first install may take a second `systemctl restart`.

        Plugins built with `lib.inventreePlugin` can declare the settings they need
        (`pluginConfigs` there); those are merged in automatically, so you only
        set what a plugin does not already require. Settings that several
        sources agree on merge silently (`ENABLE_PLUGINS_URL = true` and
        `INVENTREE_ENABLE_PLUGINS_URL = "True"` are the same setting), but a
        key two sources set to *different* values - a plugin against another
        plugin, or against this option - fails the build with an assertion
        naming each value and where it came from.
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
          PostgreSQL role (`INVENTREE_DB_USER`).
        '';
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the PostgreSQL password.
        '';
      };
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "postgres:13";
        description = ''Postgres container image version.  In general, changing 
          versions requires the database files to be upgraded.

          InvenTree versions 0.11..0.17 use postgres:13; versions 1.0.x and 1.1.x 
          use either postgres:13 or postgres:17; and from 1.2.x to present 
          versions, only postgres:17 is used.
          
          The appropriate image is set by default.  Unless you are
          executing a specific upgrade action, you should normally leave this unset.
        '';
      };
    };

    caddy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''Use the Caddy reverse proxy for HTTPS service.
      
        From 0.14, InvenTree Docker uses its own Caddy, but this option can  
        disable it if desired.
      '';
    };

    certUid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default =
        if !cfg.caddy.enable then null
        else if caddyGen then "root"
        else "caddy";
      description = ''Informational option used with Tailscale for certificate management.'';
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
              Path to a file containing the SMTP password, read at service start.
              Required when `host` is set.
            '';
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    assertions = [
      {
        assertion = lib.all (o: builtins.match "https?://[^/]+" o != null) cfg.cors.whitelist;
        message = "services.inventree.cors.whitelist entries must look like `https://host[:port]` (scheme required, no path or trailing slash); got: ${builtins.toJSON cfg.cors.whitelist}.";
      }
      {
        assertion = cfg.database.passwordFile != null;
        message = "services.inventree.database.passwordFile must be set when services.inventree.enable is true.";
      }
      {
        assertion = cfg.smtp.host != "" -> cfg.smtp.passwordFile != null;
        message = "services.inventree.smtp.passwordFile must be set when services.inventree.smtp.host is non-empty.";
      }
      {
        assertion = !(cfg.smtp.useTls && cfg.smtp.useSsl);
        message = "services.inventree.smtp: useTls and useSsl are mutually exclusive.";
      }
      {
        assertion = !(lib.versionAtLeast cfg.version "1.2.0"
          && cfg.database.image != null
          && lib.hasInfix ":13" cfg.database.image);
        message = "InvenTree ${cfg.version} (Django 5.2) requires PostgreSQL 14+, but services.inventree.database.image is pinned to a 13 image. Migrate the cluster first - https://inventree.org/blog/2026/02/12/db-update - then set database.image to \"postgres:17\" (or null). 1.1.12 is the last version that runs on postgres:13.";
      }
      {
        assertion = lib.all (p: (p.package != null) != (p.path != null)) (lib.attrValues cfg.plugins);
        message = "services.inventree.plugins: each entry must set exactly one of `package` and `path` (offending: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: p: (p.package != null) == (p.path != null)) cfg.plugins))}).";
      }
      {
        assertion = lib.all (e: !e.active || e.slug != null) pluginEntries;
        message = "services.inventree.plugins: active entries need a `slug` (set it, or use a package whose passthru.inventreePlugin declares one) - missing for: ${lib.concatStringsSep ", " (map (e: e.label) (lib.filter (e: e.active && e.slug == null) pluginEntries))}.";
      }
      {
        assertion = pluginConfigConflicts == { };
        message = "services.inventree: conflicting plugin settings (a plugin's `pluginConfigs` against another plugin's or against services.inventree.pluginConfigs) - resolve by dropping one side:"
          + lib.concatStrings (lib.mapAttrsToList
            (key: ss: "\n  ${key}: " + lib.concatStringsSep " vs " (map (s: ''"${s.val}" (${s.source})'') ss))
            pluginConfigConflicts);
      }
      {
        assertion = lib.allUnique activeSlugs;
        message = "services.inventree.plugins: two active entries share a slug (${lib.concatStringsSep ", " activeSlugs}).";
      }
      {
        assertion = lib.allUnique (map (e: e.name) pluginEntries);
        message = "services.inventree.plugins: two entries install under the same name (${lib.concatStringsSep ", " (map (e: e.name) pluginEntries)}); each plugin module / dev directory name must be unique.";
      }
    ];

    warnings =
      lib.concatMap
        (e:
          let
            r = e.drv.passthru.inventreePlugin.inventreeVersions or null;
            below = r != null && r ? min && lib.versionOlder cfg.version r.min;
            above = r != null && r ? max && lib.versionOlder r.max cfg.version;
          in
          lib.optional (e.drv != null && (below || above))
            "services.inventree.plugins: ${e.drv.name} declares InvenTree versions ${builtins.toJSON r}, but version ${cfg.version} is selected.")
        pluginEntries
      ++ lib.optional (activeSlugs != [ ] && !lib.versionAtLeast cfg.version "1.0.0")
        "services.inventree.plugins: ${lib.concatStringsSep ", " activeSlugs} are `active` on ${cfg.version}, but INVENTREE_PLUGINS_MANDATORY is an InvenTree 1.x feature and is ignored on earlier releases - activate those plugins by hand in the admin UI (or set `active = false` to silence this).";

    systemd.tmpfiles.rules = [
      # Wide open: the postgres/inventree images use their own internal UIDs which don't map
      # to anything on the host, and it isn't worth chasing exact numbers here. On a
      # bare host this is dataDir; inside a container it is the mount point (perms
      # propagate through the bind mount to the host directory).
      "d ${paths.extVolume} 0777 root root -"
    ];

    virtualisation.docker = {
      enable = lib.mkDefault true;
      storageDriver = lib.mkDefault "overlay2";
    };

    environment.systemPackages = [ pkgs.docker-compose ];

    environment.etc = {
      "inventree-docker/docker-compose.yml".text = dockerComposeYml;
      "inventree-docker/${selected.proxyConfig.file}".text = selected.proxyConfig.text;
    } // lib.optionalAttrs (composeOverride != null) {
      "inventree-docker/docker-compose.override.yml".text = composeOverride;
    };

    systemd.services.inventree = {
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
      #
      # Plugins need no install step: `plugins` is a store `linkFarm`
      # that `INVENTREE_PLUGIN_DIR` points at, bind-mounted in via the compose
      # override, so they are already in place when `migrate` runs.
      preStart = ''
        set -o errexit
        install -m 600 ${envTemplate} ${inventree.composeDir}/.env
        echo "INVENTREE_DB_PASSWORD=$(cat ${paths.dbPassword})" \
          >> ${inventree.composeDir}/.env
      '' + lib.optionalString (cfg.smtp.host != "") ''
        echo "INVENTREE_EMAIL_PASSWORD=$(cat ${paths.smtpPassword})" \
          >> ${inventree.composeDir}/.env
      '' + ''

        # A version switch renames the containers (0.13+ dropped the fixed
        # container_name:), so the previous stack can still be up against the
        # same data volume. Tear down whatever is running before starting the
        # selected version - all persistent state is in the data dir, not the
        # containers.
        docker-compose ${composeFileArgs} down --remove-orphans || true
        docker rm -f inventree-db inventree-cache inventree-server inventree-worker inventree-proxy 2>/dev/null || true

        docker-compose ${composeFileArgs} up -d inventree-db
        docker-compose ${composeFileArgs} run --rm inventree-server invoke wait
        docker-compose ${composeFileArgs} run --rm inventree-server invoke migrate
        docker-compose ${composeFileArgs} run --rm inventree-server invoke static
      '';

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = inventree.composeDir;
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose ${composeFileArgs} up --remove-orphans";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose ${composeFileArgs} down";
        ExecStopPost = "${pkgs.coreutils}/bin/shred -u ${inventree.composeDir}/.env";
        Restart = "on-failure";
        RestartSec = 10;
        # First-run migrations (full schema + rebuild_models/rebuild_thumbnails +
        # collectstatic) can comfortably outrun systemd's 90s default.
        TimeoutStartSec = 1200;
      };
    };

    # nginx generation only: the stack has no TLS front, so run a NixOS Caddy for
    # the tailnet certificate. The caddy generation's stack already ships Caddy.
    services.caddy = lib.mkIf (tlsFront && !caddyGen) {
      enable = true;
      virtualHosts.${cfg.virtualHost} = {
        extraConfig = ''
          reverse_proxy http://localhost:${toString cfg.port}
        '';
      };
    };
  }

    # Make adjustments for running inside a ctrnet instance.
    (lib.optionalAttrs containerised {
      # The stack is Docker; have the wrapper set up docker-in-nspawn for us.
      ctrnet.docker.enable = true;

      ctrnet.bindMounts = {
        ${paths.extVolume} = { hostPath = cfg.dataDir; isReadOnly = false; };
        ${paths.dbPassword} = { hostPath = toString cfg.database.passwordFile; isReadOnly = true; };
      } // lib.optionalAttrs (cfg.smtp.passwordFile != null) {
        ${paths.smtpPassword} = { hostPath = toString cfg.smtp.passwordFile; isReadOnly = true; };
      }
      # Dev plugin directories live outside the store: map each onto the same
      # path in the guest so the plugin symlink (and the docker bind mount of
      # it) resolves. Store plugins arrive with the guest's closure.
      // lib.listToAttrs (map
        (e: lib.nameValuePair e.mount { hostPath = e.mount; isReadOnly = true; })
        (lib.filter (e: e.dev) pluginEntries));
    })
  ]);
}
