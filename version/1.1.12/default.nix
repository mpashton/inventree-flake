# InvenTree 1.1.12 - post-0.14 "bundled Caddy" generation, 1.x series.
# docker-compose.yml / Caddyfile are verbatim from
# https://github.com/inventree/InvenTree/tree/1.1.12/contrib/container
#
# The compose file ships `image: postgres:17`. 1.0.x and 1.1.x still run against
# an existing `postgres:13` cluster if you pin
# services.containers.inventree.database.image = "postgres:13"; InvenTree 1.2+
# hard-requires PostgreSQL 14+, which means a dump/restore into a fresh cluster.
{
  tag = "1.1.12";
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
