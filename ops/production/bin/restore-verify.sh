#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly RESTORE_ROOT="$ROOT/restore-tests"
readonly PRODUCTION_DATA="$ROOT/data/postgres"
readonly LOCK_FILE="${MIXLI_BACKUP_LOCK_FILE:-/run/lock/mixli-backup.lock}"
readonly METRICS_DIR="$ROOT/metrics"
readonly METRICS_FILE="$METRICS_DIR/restore-verify.prom"
readonly TEST_MODE="${MIXLI_RESTORE_TEST_MODE:-0}"
readonly POSTGRES_IMAGE="${MIXLI_POSTGRES_IMAGE:-}"
readonly PGBACKREST_CONFIG="${MIXLI_PGBACKREST_CONFIG:-/etc/mixli/postgres/pgbackrest.conf}"
readonly PGBACKREST_STAGED_CONFIG=/run/mixli-secrets/pgbackrest.conf
readonly LOCAL_REPO="$ROOT/backups/pgbackrest"
readonly REQUESTED_TARGET="${MIXLI_RESTORE_TARGET:-$RESTORE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ "$TEST_MODE" == '1' ]]; then
  if [[ "$POSTGRES_IMAGE" != 'mixli-postgres:test' &&
    ! "$POSTGRES_IMAGE" =~ ^mixli-postgres:[0-9a-f]{40}$ ]]; then
    printf '%s\n' 'Test restore verification requires an explicit PostgreSQL test or exact-SHA image.' >&2
    exit 64
  fi
elif [[ ! "$POSTGRES_IMAGE" =~ ^mixli-postgres:[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'Restore verification requires MIXLI_POSTGRES_IMAGE=mixli-postgres:<40-character-lowercase-SHA>.' >&2
  exit 64
fi

install -d -m 0750 "$(dirname "$LOCK_FILE")" "$RESTORE_ROOT"
install -d -o 65534 -g 65534 -m 0750 "$METRICS_DIR"
restore_root_resolved="$(realpath -m "$RESTORE_ROOT")"
production_resolved="$(realpath -m "$PRODUCTION_DATA")"
target="$(realpath -m "$REQUESTED_TARGET")"

if [[ "$target" == "$production_resolved" || "$target" != "$restore_root_resolved"/* ]]; then
  printf '%s\n' 'Restore target must be a child of the isolated restore-test root.' >&2
  exit 64
fi

exec 8>"$LOCK_FILE"
flock -n 8 || exit 75
install -d -m 0750 "$target"

if [[ "$TEST_MODE" == '1' ]]; then
  printf 'isolated\n' >"$target/restore.started"
  [[ "${MIXLI_TEST_COMMAND_FAIL:-0}" != '1' ]]
else
  chown -R 999:999 "$target"
  docker run --rm \
    -v "$target:/var/lib/postgresql" \
    -v "$LOCAL_REPO:/var/lib/pgbackrest:ro" \
    -v "$PGBACKREST_CONFIG:$PGBACKREST_STAGED_CONFIG:ro" \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
    "$POSTGRES_IMAGE" gosu postgres pgbackrest --stanza=mixli --repo=2 \
      --pg1-path=/var/lib/postgresql/18/docker restore

  container="mixli-restore-verify-$(date -u +%Y%m%d%H%M%S)-$$"
  cleanup_container() {
    docker rm -f "$container" >/dev/null 2>&1 || true
  }
  trap cleanup_container EXIT
  docker run -d --name "$container" --network none \
    -v "$target:/var/lib/postgresql" \
    -v "$PGBACKREST_CONFIG:$PGBACKREST_STAGED_CONFIG:ro" \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
    "$POSTGRES_IMAGE" -c archive_mode=off -c shared_buffers=128MB >/dev/null

  ready=0
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if docker exec "$container" pg_isready -U mixli -d mixli >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" == '1' ]]
  docker exec "$container" psql -U mixli -d mixli -v ON_ERROR_STOP=1 -Atqc \
    'SELECT count(*) FROM information_schema.tables; SELECT count(*) FROM schema_migrations;' >/dev/null
  cleanup_container
  trap - EXIT
fi

now="$(date -u +%s)"
temporary="$METRICS_DIR/.restore-verify.$$.tmp"
install -o 65534 -g 65534 -m 0640 /dev/null "$temporary"
{
  printf '%s\n' '# HELP mixli_pgbackrest_last_restore_verify_success_timestamp Unix time of the last successful isolated restore verification.'
  printf '%s\n' '# TYPE mixli_pgbackrest_last_restore_verify_success_timestamp gauge'
  printf 'mixli_pgbackrest_last_restore_verify_success_timestamp %s\n' "$now"
} >"$temporary"
mv -fT "$temporary" "$METRICS_FILE"

[[ "$target" == "$restore_root_resolved"/* && "$target" != "$restore_root_resolved" ]]
rm -rf -- "$target"
