#!/usr/bin/env bats

setup_file() {
  export COMPOSE_FILE="ops/production/compose.yaml"
  export ENV_FILE="ops/production/env/production.env.example"
  CONFIG_JSON="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json)"
  export CONFIG_JSON
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

@test "Nginx receives the release tree read-only and has a health check" {
  run jq -e '
    .services.nginx.healthcheck != null and
    (.services.nginx.volumes | any(.source == "/srv/mixli" and .target == "/srv/mixli" and .read_only == true))
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}
