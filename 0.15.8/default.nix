# InvenTree 0.15.8 - post-0.14 "bundled Caddy" generation.
# docker-compose.yml / Caddyfile are verbatim from
# https://github.com/inventree/InvenTree/tree/0.15.8/contrib/container
{
  tag = "0.15.8";
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
