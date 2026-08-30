# InvenTree 0.17.14 - post-0.14 "bundled Caddy" generation.
# docker-compose.yml / Caddyfile are verbatim from
# https://github.com/inventree/InvenTree/tree/0.17.14/contrib/container
# docker-compose.override.yml is added by this module (see that file).
{
  tag = "0.17.14";
  proxy = "caddy";
  dockerComposeYml = builtins.readFile ./docker-compose.yml;
  composeOverrideYml = builtins.readFile ./docker-compose.override.yml;
  proxyConfig = {
    file = "Caddyfile";
    text = builtins.readFile ./Caddyfile;
  };

  # Full `KEY=value` lines appended verbatim to the generated .env for this
  # release. None needed yet; kept as a hook because env var names drift
  # between versions.
  extraEnv = "";
}
