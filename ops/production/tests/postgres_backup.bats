#!/usr/bin/env bats

setup() {
  IMAGE="${MIXLI_POSTGRES_IMAGE:-mixli-postgres:test}"
  SUFFIX="${BATS_TEST_NUMBER}-$$"
  CONTAINER="mixli-pg-test-${SUFFIX}"
  DATA_VOLUME="mixli-pg-data-${SUFFIX}"
  REPO_VOLUME="mixli-pg-repo-${SUFFIX}"
  CONFIG_ROOT="$(mktemp -d)"
  SOURCE_CONFIG="$CONFIG_ROOT/pgbackrest.conf"
  STAGED_CONFIG=/run/mixli-secrets/pgbackrest.conf
}

teardown() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm -f "$DATA_VOLUME" "$REPO_VOLUME" >/dev/null 2>&1 || true
  rm -rf "$CONFIG_ROOT"
}

write_local_pgbackrest_config() {
  cat >"$SOURCE_CONFIG" <<'EOF'
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-bundle=y
repo1-block=y
process-max=2
start-fast=y
spool-path=/var/spool/pgbackrest
log-path=/var/log/pgbackrest
log-level-console=info

[mixli]
pg1-path=/var/lib/postgresql/18/docker
pg1-database=mixli
pg1-user=mixli
EOF
  docker run --rm -v "$CONFIG_ROOT:/fixture" alpine:3.22 \
    sh -ceu 'chown 0:0 /fixture/pgbackrest.conf; chmod 0600 /fixture/pgbackrest.conf'
}

wait_for_postgres() {
  local attempt consecutive=0
  for attempt in $(seq 1 60); do
    if docker exec "$CONTAINER" psql -U mixli -d mixli -Atqc 'SELECT 1' >/dev/null 2>&1; then
      consecutive=$((consecutive + 1))
      if [ "$consecutive" -eq 3 ]; then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 1
  done
  docker logs "$CONTAINER" >&2
  return 1
}

@test "pgBackRest restores a sentinel row from a full local backup" {
  docker volume create "$DATA_VOLUME" >/dev/null
  docker volume create "$REPO_VOLUME" >/dev/null
  write_local_pgbackrest_config

  docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=test-only-password \
    -e POSTGRES_USER=mixli \
    -e POSTGRES_DB=mixli \
    -v "$DATA_VOLUME:/var/lib/postgresql" \
    -v "$REPO_VOLUME:/var/lib/pgbackrest" \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" -c config_file=/etc/postgresql/postgresql.conf -c shared_buffers=128MB >/dev/null

  wait_for_postgres
  docker exec --user postgres "$CONTAINER" pgbackrest --stanza=mixli stanza-create
  docker exec "$CONTAINER" psql -U mixli -d mixli -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE recovery_probe (value text NOT NULL); INSERT INTO recovery_probe VALUES ('mixli-restored');"
  docker exec --user postgres "$CONTAINER" pgbackrest --stanza=mixli --type=full backup

  docker rm -f "$CONTAINER" >/dev/null
  docker run --rm -v "$DATA_VOLUME:/target" alpine:3.22 sh -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
  docker run --rm --user 0 \
    -v "$DATA_VOLUME:/var/lib/postgresql" \
    -v "$REPO_VOLUME:/var/lib/pgbackrest" \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" bash -c 'mkdir -p /var/lib/postgresql/18/docker && chown -R postgres:postgres /var/lib/postgresql /var/lib/pgbackrest'
  docker run --rm \
    -v "$DATA_VOLUME:/var/lib/postgresql" \
    -v "$REPO_VOLUME:/var/lib/pgbackrest" \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" gosu postgres pgbackrest --stanza=mixli restore

  docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=test-only-password \
    -e POSTGRES_USER=mixli \
    -e POSTGRES_DB=mixli \
    -v "$DATA_VOLUME:/var/lib/postgresql" \
    -v "$REPO_VOLUME:/var/lib/pgbackrest" \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" -c config_file=/etc/postgresql/postgresql.conf -c shared_buffers=128MB >/dev/null
  wait_for_postgres

  run docker exec "$CONTAINER" psql -U mixli -d mixli -Atqc 'SELECT value FROM recovery_probe'
  [ "$status" -eq 0 ]
  [ "$output" = "mixli-restored" ]
}

@test "R2 example contains no credentials and requires encrypted S3 settings" {
  local config="ops/production/postgres/pgbackrest.conf.example"

  run grep -E 'repo2-type[[:space:]]*=[[:space:]]*s3' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'repo2-s3-region[[:space:]]*=[[:space:]]*auto' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'repo2-s3-uri-style[[:space:]]*=[[:space:]]*path' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'repo2-cipher-type[[:space:]]*=[[:space:]]*aes-256-cbc' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'repo2-retention-full[[:space:]]*=[[:space:]]*2' "$config"
  [ "$status" -eq 0 ]
  run grep -Ei '(access|secret|cipher-pass)[[:space:]]*=[[:space:]]*[^<{[:space:]]+' "$config"
  [ "$status" -ne 0 ]
}
