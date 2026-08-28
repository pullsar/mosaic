#!/usr/bin/env bats

setup_file() {
  CONFIG_JSON="$(docker compose --env-file ops/production/env/production.env.example -f ops/production/compose.yaml config --format json)"
  export CONFIG_JSON
}

@test "all monitoring services are private, bounded, and on the monitoring network" {
  run jq -e '
    . as $cfg |
    ["prometheus", "alertmanager", "grafana", "node-exporter", "cadvisor", "nginx-exporter", "postgres-exporter"] | all(
      . as $service |
      ($cfg.services[$service].ports == null) and
      ($cfg.services[$service].networks | has("monitoring")) and
      ($cfg.services[$service].deploy.resources.limits.memory != null) and
      ($cfg.services[$service].image | endswith(":latest") | not)
    )
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "Prometheus scrapes every required production signal" {
  local config="ops/production/prometheus/prometheus.yml"
  for target in prometheus:9090 api-blue-1:8080 api-blue-2:8080 api-green-1:8080 api-green-2:8080 node-exporter:9100 cadvisor:8080 nginx-exporter:9113 postgres-exporter:9187; do
    grep -q "$target" "$config"
  done
  grep -q 'alertmanager:9093' "$config"
  grep -q '/etc/prometheus/rules.yml' "$config"
}

@test "node exporter collects backup and restore textfiles" {
  run jq -e '
    (.services["node-exporter"].command | any(contains("--collector.textfile.directory=/var/lib/node_exporter/textfile"))) and
    (.services["node-exporter"].volumes | any(.source == "/srv/mixli/metrics" and .read_only == true))
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "alert rules cover availability, SLOs, capacity, database, and recovery" {
  local rules="ops/production/prometheus/rules.yml"
  for alert in TargetDown ApiUnavailable ApiHigh5xxRatio ApiHighP95Latency HostDiskLow HostMemoryLow ContainerRestarting PostgreSQLDown PostgreSQLConnectionsHigh BackupStale WalArchiveStale RestoreVerificationStale; do
    grep -q "alert: $alert" "$rules"
  done
  grep -q 'pg_stat_archiver_last_archive_age.*> 900' "$rules"
  grep -q 'mixli_pgbackrest_last_backup_success_timestamp.*93600' "$rules"
  grep -q 'mixli_pgbackrest_last_restore_verify_success_timestamp.*3024000' "$rules"
}

@test "Alertmanager reads its webhook URL from a root-owned file" {
  grep -q 'url_file: /etc/alertmanager/secrets/webhook-url' ops/production/alertmanager/alertmanager.yml
  run jq -e '
    (.services.alertmanager.volumes | any(.target == "/etc/alertmanager/secrets/webhook-url" and .read_only == true))
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "Grafana dashboard and datasource use the provisioned Prometheus UID" {
  grep -q 'uid: mixli-prometheus' ops/production/grafana/provisioning/datasources/prometheus.yml
  grep -q 'mixli-prometheus' ops/production/grafana/provisioning/dashboards/mixli-overview.json
}
