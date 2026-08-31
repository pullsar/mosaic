#!/usr/bin/env bats

setup_file() {
  export COMPOSE_FILE="ops/production/compose.yaml"
  export ENV_FILE="ops/production/env/production.env.example"
  local synthetic_api_env="$BATS_FILE_TMPDIR/api.env"
  local synthetic_exporter_env="$BATS_FILE_TMPDIR/postgres-exporter.env"
  local default_env="$BATS_FILE_TMPDIR/production-without-browser-origin.env"
  : >"$synthetic_api_env"
  : >"$synthetic_exporter_env"
  grep -v '^MOSAIC_WEB_ORIGINS=' "$ENV_FILE" >"$default_env"
  CONFIG_JSON="$(
    env -u MIXLI_API_IMAGE -u MIXLI_POSTGRES_IMAGE \
      MIXLI_API_ENV_FILE="$synthetic_api_env" \
      MIXLI_POSTGRES_EXPORTER_ENV_FILE="$synthetic_exporter_env" \
      docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json
  )"
  DEFAULT_CONFIG_JSON="$(
    env -u MOSAIC_WEB_ORIGINS -u MIXLI_API_IMAGE -u MIXLI_POSTGRES_IMAGE \
      MIXLI_API_ENV_FILE="$synthetic_api_env" \
      MIXLI_POSTGRES_EXPORTER_ENV_FILE="$synthetic_exporter_env" \
      docker compose --env-file "$default_env" -f "$COMPOSE_FILE" config --format json
  )"
  CUSTOM_CONFIG_JSON="$(
    env -u MIXLI_API_IMAGE -u MIXLI_POSTGRES_IMAGE \
      MOSAIC_WEB_ORIGINS='https://preview.mixli.app' \
      MIXLI_API_ENV_FILE="$synthetic_api_env" \
      MIXLI_POSTGRES_EXPORTER_ENV_FILE="$synthetic_exporter_env" \
      docker compose --env-file "$default_env" -f "$COMPOSE_FILE" config --format json
  )"
  export CONFIG_JSON DEFAULT_CONFIG_JSON CUSTOM_CONFIG_JSON
}

@test "Nginx is the only service publishing host ports" {
  run jq -e '
    [.services | to_entries[] | select(.value.ports != null) | .key] == ["nginx"] and
    (.services.nginx.ports | map(.published) | sort) == ["443", "80"]
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "PostgreSQL and all four API replicas are private and health checked" {
  run jq -e '
    (["postgres", "api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service |
      ($cfg.services[$service].ports == null) and
      ($cfg.services[$service].healthcheck != null) and
      ($cfg.services[$service].networks | has("backend"))
    ))
  ' --argjson cfg "$CONFIG_JSON" <<<"{}"
  [ "$status" -eq 0 ]
}

@test "application replicas are immutable and resource bounded" {
  run jq -e '
    . as $cfg |
    ["api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service |
      ($cfg.services[$service].read_only == true) and
      ($cfg.services[$service].tmpfs | any(startswith("/tmp"))) and
      ($cfg.services[$service].security_opt | any(startswith("no-new-privileges"))) and
      ($cfg.services[$service].deploy.resources.limits.memory == "1073741824") and
      ($cfg.services[$service].deploy.resources.reservations.cpus == 0.75)
    )
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "backend and monitoring networks are internal" {
  run jq -e '.networks.backend.internal == true and .networks.monitoring.internal == true' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "Nginx alone joins a non-masqueraded edge network for published ingress" {
  run jq -e '
    . as $cfg |
    ($cfg.networks.edge.internal != true) and
    ($cfg.networks.edge.driver_opts."com.docker.network.bridge.enable_ip_masquerade" == "false") and
    ($cfg.services.nginx.networks | has("edge")) and
    ([.services | to_entries[] | select(.value.networks | has("edge")) | .key] == ["nginx"])
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "database and APIs have outbound-only network access for R2 and push providers" {
  run jq -e '
    . as $cfg |
    ($cfg.networks.egress.internal != true) and
    (["postgres", "api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service | ($cfg.services[$service].networks | has("egress"))
    ))
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "PostgreSQL has persistent mounts and a 16 GiB memory limit" {
  run jq -e '
    .services.postgres.deploy.resources.limits.memory == "17179869184" and
    (.services.postgres.volumes | map(.source) | index("/srv/mixli/data/postgres") != null) and
    (.services.postgres.volumes | map(.source) | index("/srv/mixli/backups/pgbackrest") != null)
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "Docker daemon restart cannot publish Nginx before the firewall unit" {
  run jq -e '.services.nginx.restart == "no"' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
  grep -Fq 'Requires=docker.service mixli-cloudflare-ips.service' \
    ops/production/systemd/mixli-stack.service
}

@test "bootstrap PostgreSQL image cannot collide with CI or a mutable production tag" {
  run jq -e '
    .services.postgres.image == "mixli-postgres:bootstrap-required"
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
  grep -Fxq 'MIXLI_POSTGRES_IMAGE=mixli-postgres:bootstrap-required' "$ENV_FILE"
}

@test "PostgreSQL stages the root-only pgBackRest config and requires production S3 settings" {
  run jq -e '
    (.services.postgres.volumes | any(
      .source == "/etc/mixli/postgres/pgbackrest.conf" and
      .target == "/run/mixli-secrets/pgbackrest.conf" and
      .read_only == true
    )) and
    (.services.postgres.volumes | all(.target != "/etc/pgbackrest/pgbackrest.conf")) and
    (.services.postgres.environment.MIXLI_PGBACKREST_REQUIRE_REPO2_S3 == "1")
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "Nginx receives the release tree read-only and has a health check" {
  run jq -e '
    .services.nginx.healthcheck != null and
    (.services.nginx.volumes | any(.source == "/srv/mixli" and .target == "/srv/mixli" and .read_only == true))
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "all API replicas receive the strict Mixli browser origin allowlist" {
  run jq -e '
    . as $cfg |
    ["api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service |
      $cfg.services[$service].environment.MOSAIC_WEB_ORIGINS ==
        "https://mixli.app,https://www.mixli.app"
    )
  ' <<<"$DEFAULT_CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "browser origin allowlist remains explicitly overrideable" {
  run jq -e '
    . as $cfg |
    ["api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service |
      $cfg.services[$service].environment.MOSAIC_WEB_ORIGINS ==
        "https://preview.mixli.app"
    )
  ' <<<"$CUSTOM_CONFIG_JSON"
  [ "$status" -eq 0 ]
}
