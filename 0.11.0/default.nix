# InvenTree 0.11.0 - pre-0.14 "nginx reverse proxy" generation.
# docker-compose.yml / nginx.prod.conf are verbatim from
# https://github.com/inventree/InvenTree/tree/0.11.0/docker/production
{
  tag = "0.11.0";
  dockerComposeYml = builtins.readFile ./docker-compose.yml;
  nginxProdConf = builtins.readFile ./nginx.prod.conf;

  # Full `KEY=value` lines appended verbatim to the generated .env for this
  # release. None needed yet; kept as a hook because env var names drift
  # between versions.
  extraEnv = "";
}
