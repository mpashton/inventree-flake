# InvenTree 1.7.0 - post-0.14 "bundled Caddy" generation, 1.x series.
# docker-compose.yml / Caddyfile are verbatim from
# https://github.com/inventree/InvenTree/tree/1.7.0/contrib/container
#
# 1.2+ (Django 5.2) requires PostgreSQL 14+. If you are still on a postgres:13
# cluster, migrate it before bumping past 1.1
# (https://inventree.org/blog/2026/02/12/db-update).
{
  tag = "1.7.0";
  proxy = "caddy";
  dockerComposeYml = builtins.readFile ./docker-compose.yml;
  proxyConfig = {
    file = "Caddyfile";
    text = builtins.readFile ./Caddyfile;
  };

  # Full `KEY=value` lines appended verbatim to the generated .env for this
  # release. None needed yet; kept as a hook because env var names drift
  # between versions.
  extraEnv = "";
}
