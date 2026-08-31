#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly OPERATION="${1-}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly LOCK_FILE="${MIXLI_BACKUP_LOCK_FILE:-/run/lock/mixli-backup.lock}"
readonly METRICS_DIR="$ROOT/metrics"
readonly METRICS_FILE="$METRICS_DIR/pgbackrest.prom"
readonly COMPOSE_FILE="${MIXLI_COMPOSE_FILE:-/srv/mixli/runtime/compose.yaml}"
readonly ENV_FILE="${MIXLI_ENV_FILE:-/etc/mixli/env/production.env}"
readonly TEST_MODE="${MIXLI_BACKUP_TEST_MODE:-0}"

case "$OPERATION" in
  full | incr | check) ;;
  *)
    printf '%s\n' 'Usage: backup.sh {full|incr|check}' >&2
    exit 64
    ;;
esac

install -d -m 0750 "$(dirname "$LOCK_FILE")"
install -d -o 65534 -g 65534 -m 0750 "$METRICS_DIR"
exec 8>"$LOCK_FILE"
flock -n 8 || exit 75

run_pgbackrest() {
  if [[ "$TEST_MODE" == '1' ]]; then
    "${MIXLI_PGBACKREST_COMMAND:?MIXLI_PGBACKREST_COMMAND is required in test mode}" "$@"
  else
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
      exec -T --user postgres postgres pgbackrest --stanza=mixli "$@"
  fi
}

if [[ "$OPERATION" != 'check' ]]; then
  for repo in 1 2; do
    run_pgbackrest "--repo=$repo" "--type=$OPERATION" backup
  done
fi
run_pgbackrest check

now="$(date -u +%s)"
last_backup=''
if [[ -f "$METRICS_FILE" ]]; then
  last_backup="$(awk '$1 == "mixli_pgbackrest_last_backup_success_timestamp" {print $2}' "$METRICS_FILE" | tail -n 1)"
fi
if [[ "$OPERATION" != 'check' ]]; then
  last_backup="$now"
fi

temporary="$METRICS_DIR/.pgbackrest.$$.tmp"
install -o 65534 -g 65534 -m 0640 /dev/null "$temporary"
{
  printf '%s\n' '# HELP mixli_pgbackrest_last_backup_success_timestamp Unix time of the last successful backup to both repositories.'
  printf '%s\n' '# TYPE mixli_pgbackrest_last_backup_success_timestamp gauge'
  [[ -z "$last_backup" ]] || printf 'mixli_pgbackrest_last_backup_success_timestamp %s\n' "$last_backup"
  printf '%s\n' '# HELP mixli_pgbackrest_last_check_success_timestamp Unix time of the last successful repository check.'
  printf '%s\n' '# TYPE mixli_pgbackrest_last_check_success_timestamp gauge'
  printf 'mixli_pgbackrest_last_check_success_timestamp %s\n' "$now"
} >"$temporary"
mv -fT "$temporary" "$METRICS_FILE"
