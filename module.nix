# The InvenTree stack: InvenTree's upstream production docker-compose files,
# driven by a systemd unit, with a small NixOS Caddy in front for the pre-0.14
# ("nginx") generation.
#
# This module configures the stack on whatever NixOS system imports it - a host
# directly (Docker only), or the inner system of a container. It does *not* do
# any nspawn / VM wrapping and does *not* join a tailnet: hand
# `services.ctrnet.<name>.modules = [ this ]` (or your own container /
# host config) the containerisation and Tailscale. When `caddy.enable`, the
# stack's TLS front needs a reachable `tailscaled` that permits
# {option}`services.inventree.certUid` to fetch the `*.ts.net` cert.
{ config, lib, pkgs, options, ... }:

let
  cfg = config.services.inventree;

  # A `service-container` wrapper declares `options.serviceContainer.bindMounts`;
  # its presence means we're the inner system of one. Then we use fixed
  # in-container paths and hand the wrapper the host directories to bind-mount
  # there. On a bare host we use the operator's `dataDir` / `*File` paths as-is.
  containerised = options ? serviceContainer;

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
  # see lib/mk-plugin.nix) or a dev directory (`path`). The custom plugin
  # directory is a store `linkFarm` with one symlink per entry, so the
  # containers need every link *target* visible at the same path - see
  # `pluginMounts`. Built tolerantly: a malformed entry (neither / both of
  # package and path) is reported by an assertion, not an evaluation error.
  pluginEntries = lib.mapAttrsToList
    (label: p:
      if p.package != null then
        let
          m = p.package.passthru.inventreePlugin.module or (throw
            "services.inventree.plugins.${label}: ${p.package.name} has no `passthru.inventreePlugin.module` - build it with inventree-flake's `lib.mkPlugin`, or set that attribute and install the plugin to $out/<module>.");
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
    enable = lib.mkEnableOption ''
      an InvenTree instance (releases 0.11 through 1.6) running its upstream
      production docker-compose stack. Wrap it in a container yourself (e.g.
      services.ctrnet) or run it straight on the host
    '';

    version = lib.mkOption {
      type = lib.types.enum (lib.attrNames versions);
      default = "0.17.14";
      description = ''
        Which InvenTree release to run. Two proxy generations are offered:
        0.11-0.13 (the stack ships nginx; this module fronts it with a NixOS
        Caddy) and 0.14 onward (the stack ships its own Caddy). 0.17.14 is the
        last release before the 1.0 rewrite; 1.1.12 is the last that runs on a
        `postgres:13` cluster (1.2+ needs PostgreSQL 14+ - see
        {option}`services.inventree.database.image`).

        Raising this is an in-place upgrade against the shared
        {option}`services.inventree.dataDir` database - schema
        migrations run automatically on every start. Downgrades are not
        supported. Releases up to 0.17 are past upstream security support and
        must stay off the public internet; 1.x is current.
      '';
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "inventree";
      description = ''
        Short name for this instance - the default source for
        {option}`services.inventree.virtualHost` and
        {option}`services.inventree.composeProjectName`.
      '';
    };

    virtualHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.inventree.hostname";
      description = ''
        Host name InvenTree is reached at. For 0.11-0.13 it is the NixOS Caddy's
        vhost; for 0.14 onward it is the host part of
        {option}`services.inventree.siteUrl`. Set it to the
        fully-qualified name users type (e.g. the `<host>.<tailnet>.ts.net`
        MagicDNS name).
      '';
    };

    siteUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.virtualHost}";
      defaultText = lib.literalExpression ''"https://" + config.services.inventree.virtualHost'';
      description = ''
        `INVENTREE_SITE_URL` - the canonical externally-visible URL. Used from
        the 0.14 (Caddy) generation on: it is the bundled Caddy's site address
        (an `https://<name>.ts.net` value makes Caddy fetch the tailnet
        certificate automatically), and InvenTree derives its CSRF trusted
        origins from it - mandatory from 0.16, the server refuses to start
        without it. Ignored by the 0.11-0.13 (nginx) generation.
      '';
    };

    cors = {
      allowAll = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          `INVENTREE_CORS_ORIGIN_ALLOW_ALL` - let web pages from *any* origin
          read API responses in a visitor's browser. InvenTree's shipped
          `config.yaml` enables this, which raises warning INVE-W16, so the
          module forces it off unless you ask for it. Only turn it on for
          development or a deliberately public, credential-free API.
        '';
      };

      whitelist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "https://dashboard.example.com" ];
        description = ''
          `INVENTREE_CORS_ORIGIN_WHITELIST` - extra origins (scheme and host,
          optional port, no path or trailing slash) whose browser scripts may
          read API responses. Same-origin access, i.e. the web UI itself, never
          needs an entry, and from 1.x InvenTree adds
          {option}`services.inventree.siteUrl` automatically. Only useful for
          a second hostname or a separate web app that calls the API from
          the browser. Ignored while {option}`services.inventree.cors.allowAll`
          is true.
        '';
      };
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1337;
      description = ''
        Plain-HTTP port the InvenTree stack's proxy publishes.
        0.11-0.13: the NixOS Caddy (or, with
        {option}`services.inventree.caddy.enable` = false, your own
        proxy) reverse-proxies to `http://localhost:<port>`. 0.14 onward: the
        bundled Caddy takes :80 and :443 directly, and this only applies when
        `caddy.enable` = false - it becomes the HTTP port (`INVENTREE_WEB_PORT`
        up to 0.17, `INVENTREE_HTTP_PORT` from 1.0).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/inventree/data";
      description = ''
        **External** host directory holding InvenTree's single data volume (the
        postgres cluster, media, static files, Django secret key). On a bare
        host this is used directly as `INVENTREE_EXT_VOLUME`; inside a
        `service-container` the module bind-mounts it onto a fixed in-container
        path automatically (no `bindMounts` entry needed). Switching
        {option}`services.inventree.version` migrates this database in
        place, so keep it stable across upgrades.
      '';
    };

    composeProjectName = lib.mkOption {
      type = lib.types.str;
      default = cfg.hostname;
      defaultText = lib.literalExpression "config.services.inventree.hostname";
      description = ''
        `COMPOSE_PROJECT_NAME` for the stack. Only a label - but it names the
        docker resources, so changing it on a running instance orphans the old
        containers. Pin it if you rename the instance.
      '';
    };

    tailscaleSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/tailscale/tailscaled.sock";
      description = ''
        Path to the `tailscaled` control socket, bind-mounted into the bundled
        Caddy (0.14+ with `caddy.enable`) so it can fetch the `*.ts.net`
        certificate for {option}`services.inventree.siteUrl`. It must be
        reachable in this instance's filesystem - the NixOS default when
        Tailscale runs here, or a path a container wrapper bind-mounts in.
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
            description = ''
              The plugin, as a derivation. Defaults to the in-tree plugin
              (`pkgs.inventreePlugins`) named like the attribute, so
              `plugins.ipn-generator = { };` is enough for those.
              `$out/<module>` holds its Python
              package (or a single `<module>.py`) and
              `passthru.inventreePlugin.module` names it. Build one with
              inventree-nix's `lib.mkPlugin`, or by hand. Exactly one of
              `package` and `path` must be set.
            '';
          };

          path = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "/.+");
            default = null;
            example = "/home/me/src/my-plugin/my_plugin";
            description = ''
              A plugin directory on the host, for development. Absolute
              *string* (not a Nix path literal, which would be copied to the
              store). It is symlinked into the plugin directory under its
              basename and bind-mounted read-only (at
              `/opt/inventree-dev-plugins/<basename>` in the containers), so
              edits are live after a restart. Exactly one of `package` and
              `path` must be set.
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
            description = ''
              The plugin's InvenTree **slug** (its `SLUG`, not a PyPI name),
              used to force-activate it. Taken from the package when it
              declares one; a `path` entry that is `active` must set it.
            '';
          };

          active = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Force the plugin active on every start: its slug is added to
              `INVENTREE_PLUGINS_MANDATORY`, so it cannot be disabled from the
              UI. Set `false` to leave activation to the admin UI (Settings →
              Plugins). InvenTree **1.x only** - earlier releases ignore the
              setting (the module warns) and need the plugins activated by hand
              in the admin UI.
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

        Plugins built with `lib.mkPlugin` can declare the settings they need
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
          PostgreSQL role the stack connects as (`INVENTREE_DB_USER`). The
          bundled postgres container creates this role on first run; for an
          existing database it must match the role that already owns it.
        '';
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the PostgreSQL password, read at service
          start - never copied into the store. Required when the module is
          enabled. In a container, bind-mount the host secret at this same path.
        '';
      };
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "postgres:13";
        description = ''
          Override the PostgreSQL container image. `null` uses whatever the
          selected version's compose file ships: `postgres:13` for 0.11-0.17,
          `postgres:17` for 1.0+.

          Postgres major versions store their on-disk data incompatibly, so this
          cannot simply jump: the 0.11-0.17 line runs on `postgres:13`, and
          1.0.x / 1.1.x still run against a 13 cluster if you pin
          `"postgres:13"` here. Moving to `postgres:17` (required by InvenTree
          1.2+) means a dump/restore into a fresh cluster - do that while on
          1.1.x following <https://inventree.org/blog/2026/02/12/db-update>, then
          set this back to `null`.
        '';
      };
    };

    caddy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Have the stack terminate HTTPS for {option}`...virtualHost` itself. For
        0.11-0.13 this runs a NixOS `services.caddy` in front of the stack's
        nginx; for 0.14 onward the stack already ships Caddy, so this just serves
        {option}`...siteUrl` on :443 with a Tailscale certificate (needs a
        `tailscaled` reachable at {option}`...tailscaleSocket` that permits
        {option}`services.inventree.certUid`). Disable to put your own
        reverse proxy in front, pointing at `http://localhost:<port>`.
      '';
    };

    certUid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default =
        if !cfg.caddy.enable then null
        else if caddyGen then "root"
        else "caddy";
      description = ''
        (read-only) Which uid needs permission to fetch the `*.ts.net`
        certificate for this instance's front door: `"root"` for the 0.14+
        bundled Caddy, `"caddy"` for the 0.11-0.13 NixOS Caddy, `null` when
        `caddy.enable` is false. Feed this to your container wrapper's
        Tailscale `permitCertUid` (`TS_PERMIT_CERT_UID`).
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

    # Inside a service-container: hand the wrapper the external directories to
    # bind-mount onto our fixed in-container paths, so no `bindMounts` clause is
    # needed at the call site. (The data volume; the secret files, so
    # preStart's `cat` works.) `optionalAttrs`, not `mkIf`: on a bare host the
    # `serviceContainer` option isn't declared, so the attr must not appear at
    # all.
    (lib.optionalAttrs containerised {
      # The stack is Docker; have the wrapper set up docker-in-nspawn for us.
      serviceContainer.docker.enable = true;

      serviceContainer.bindMounts = {
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
