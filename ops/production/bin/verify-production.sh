#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly MODE="${1-}"
readonly TEST_MODE="${MIXLI_VERIFY_TEST_MODE:-0}"
readonly FAIL_CHECK="${MIXLI_VERIFY_FAIL_CHECK:-}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly STATE_FILE="$ROOT/state/current.json"
readonly METRICS_FILE="$ROOT/metrics/pgbackrest.prom"
readonly COMPOSE_FILE="${MIXLI_COMPOSE_FILE:-/srv/mixli/runtime/compose.yaml}"
readonly ENV_FILE="${MIXLI_ENV_FILE:-/etc/mixli/env/production.env}"
readonly ORIGIN_CERT="${MIXLI_ORIGIN_CERT:-/etc/mixli/cloudflare/origin.pem}"
readonly ORIGIN_CA="${MIXLI_ORIGIN_CA:-/etc/mixli/cloudflare/origin-ca.pem}"
readonly ORIGIN_KEY="${MIXLI_ORIGIN_KEY:-/etc/mixli/cloudflare/origin.key}"

passed=0
failed=0

usage() {
  printf '%s\n' 'Usage: verify-production.sh {--origin|--public}' >&2
  exit 64
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

nginx_origin_ip() {
  local container_id origin_ip
  container_id="$(compose ps -q nginx)"
  [[ -n "$container_id" ]]
  origin_ip="$(docker inspect --format \
    '{{with index .NetworkSettings.Networks "mixli_backend"}}{{.IPAddress}}{{end}}' \
    "$container_id")"
  [[ "$origin_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
  printf '%s\n' "$origin_ip"
}

run_check() {
  local label="$1" implementation="$2"
  if [[ "$TEST_MODE" == '1' ]]; then
    if [[ "$FAIL_CHECK" == "$label" ]]; then
      printf 'FAIL %s\n' "$label"
      failed=$((failed + 1))
    else
      printf 'PASS %s\n' "$label"
      passed=$((passed + 1))
    fi
    return
  fi

  if "$implementation" >/dev/null 2>&1; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$label"
    failed=$((failed + 1))
  fi
}

check_commands() {
  local command_name
  for command_name in curl openssl docker jq awk grep nft sha256sum date; do
    command -v "$command_name" >/dev/null
  done
  docker compose version >/dev/null
}

curl_endpoint() {
  local host="$1" path="$2" origin_ip
  if [[ "$MODE" == '--origin' ]]; then
    origin_ip="$(nginx_origin_ip)"
    curl --fail --silent --show-error --max-time 15 \
      --cacert "$ORIGIN_CA" --resolve "$host:443:$origin_ip" \
      "https://$host$path"
  else
    curl --fail --silent --show-error --max-time 15 "https://$host$path"
  fi
}

curl_headers() {
  local host="$1" path="$2" origin_ip
  if [[ "$MODE" == '--origin' ]]; then
    origin_ip="$(nginx_origin_ip)"
    curl --fail --silent --show-error --max-time 15 \
      --cacert "$ORIGIN_CA" --resolve "$host:443:$origin_ip" \
      --dump-header - --output /dev/null "https://$host$path"
  else
    curl --fail --silent --show-error --max-time 15 \
      --dump-header - --output /dev/null "https://$host$path"
  fi
}

check_http_tls() {
  local cert_key private_key
  curl_endpoint mixli.app / >/dev/null
  [[ "$(curl_endpoint api.mixli.app /health | jq -r '.status')" == 'ok' ]]
  [[ "$(curl_endpoint api.mixli.app /ready | jq -r '.status')" == 'ready' ]]

  if [[ "$MODE" == '--origin' ]]; then
    [[ -s "$ORIGIN_CERT" && -s "$ORIGIN_KEY" ]]
    openssl x509 -in "$ORIGIN_CERT" -checkend 2592000 -noout
    cert_key="$(openssl x509 -in "$ORIGIN_CERT" -pubkey -noout | \
      openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    private_key="$(openssl pkey -in "$ORIGIN_KEY" -pubout -outform DER 2>/dev/null | \
      sha256sum | awk '{print $1}')"
    [[ -n "$cert_key" && "$cert_key" == "$private_key" ]]
  else
    openssl s_client -connect api.mixli.app:443 -servername api.mixli.app \
      </dev/null 2>/dev/null | openssl x509 -checkend 2592000 -noout
  fi
}

current_sha() {
  jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "$STATE_FILE"
}

current_pool() {
  jq -er '.pool | select(. == "blue" or . == "green")' "$STATE_FILE"
}

check_release_header() {
  local expected actual
  expected="$(current_sha)"
  actual="$(curl_headers api.mixli.app /health | awk '
    BEGIN { IGNORECASE=1 }
    /^x-mixli-release:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }')"
  [[ "$actual" == "$expected" ]]
}

container_id() {
  compose ps -q "$1"
}

require_running() {
  local id
  id="$(container_id "$1")"
  [[ -n "$id" ]]
  [[ "$(docker inspect --format '{{.State.Status}}' "$id")" == 'running' ]]
}

require_healthy() {
  local id
  id="$(container_id "$1")"
  [[ -n "$id" ]]
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$id")" == 'healthy' ]]
}

check_containers() {
  local pool service
  pool="$(current_pool)"
  for service in postgres nginx "api-$pool-1" "api-$pool-2"; do
    require_healthy "$service"
  done
  for service in prometheus alertmanager grafana node-exporter cadvisor nginx-exporter postgres-exporter; do
    require_running "$service"
  done
}

check_migrations() {
  local pool output
  pool="$(current_pool)"
  output="$(compose exec -T "api-$pool-1" node dist/db/migrate.js status)"
  [[ -n "$output" ]]
  ! grep -Fq '[ ]' <<<"$output"
}

metric_value() {
  local name="$1"
  awk -v metric="$name" '$1 == metric { value=$2 } END { print value }' "$METRICS_FILE"
}

fresh_metric() {
  local name="$1" max_age="$2" value now
  value="$(metric_value "$name")"
  [[ "$value" =~ ^[0-9]+$ ]]
  now="$(date -u +%s)"
  (( now >= value && now - value <= max_age ))
}

check_backup_wal() {
  local wal_age
  [[ -s "$METRICS_FILE" ]]
  fresh_metric mixli_pgbackrest_last_backup_success_timestamp 93600
  fresh_metric mixli_pgbackrest_last_check_success_timestamp 93600
  compose exec -T --user postgres postgres pgbackrest --stanza=mixli check
  # Expand the database identity inside the container, not in the host verifier.
  # shellcheck disable=SC2016
  wal_age="$(compose exec -T --user postgres postgres sh -ceu '
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc \
      "select coalesce(extract(epoch from now() - last_archived_time)::bigint, -1) from pg_stat_archiver"
  ')"
  [[ "$wal_age" =~ ^[0-9]+$ && "$wal_age" -le 900 ]]
}

check_firewall() {
  nft list table inet mixli_host_filter | grep -Fq 'policy drop'
  nft list table inet mixli_host_filter | grep -Eq 'tcp dport 22.*accept'
  nft list table inet mixli_cloudflare | grep -Fq 'hook forward priority -10'
  nft list set inet mixli_cloudflare cloudflare_v4 | grep -Fq 'elements = {'
  nft list set inet mixli_cloudflare cloudflare_v6 | grep -Fq 'elements = {'
  nft list chain inet mixli_cloudflare forward | grep -Fq 'reject'
}

main() {
  case "$MODE" in
    --origin | --public) ;;
    *) usage ;;
  esac

  run_check 'command availability' check_commands
  run_check 'HTTP and TLS' check_http_tls
  run_check 'API release header' check_release_header

  if [[ "$MODE" == '--origin' ]]; then
    run_check 'container health' check_containers
    run_check 'migration status' check_migrations
    run_check 'backup and WAL freshness' check_backup_wal
    run_check 'firewall policy' check_firewall
  fi

  printf '%d passed, %d failed\n' "$passed" "$failed"
  [[ "$failed" -eq 0 ]]
}

main
