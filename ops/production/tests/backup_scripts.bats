#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/metrics" "$TEST_ROOT/restore-tests" "$TEST_ROOT/data/postgres" "$TEST_ROOT/bin"
  COMMAND_LOG="$TEST_ROOT/commands.log"
  export COMMAND_LOG

  cat >"$TEST_ROOT/bin/pgbackrest-shim" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMMAND_LOG"
[[ "${MIXLI_TEST_COMMAND_FAIL:-0}" != '1' ]]
SH
  chmod +x "$TEST_ROOT/bin/pgbackrest-shim"

  cat >"$TEST_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMMAND_LOG"
if [[ "$1" == 'run' && " $* " == *' -d '* ]]; then
  printf '%s\n' 'synthetic-container-id'
fi
SH
  cat >"$TEST_ROOT/bin/chown" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/chown"
  printf '%s\n' '[global]' >"$TEST_ROOT/pgbackrest.conf"
  chmod 0600 "$TEST_ROOT/pgbackrest.conf"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

backup() {
  env \
    MIXLI_BACKUP_TEST_MODE=1 \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_PGBACKREST_COMMAND="$TEST_ROOT/bin/pgbackrest-shim" \
    MIXLI_TEST_COMMAND_FAIL="${MIXLI_TEST_COMMAND_FAIL:-0}" \
    "$REPO_ROOT/ops/production/bin/backup.sh" "$@"
}

restore_verify() {
  env \
    MIXLI_RESTORE_TEST_MODE=1 \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_RESTORE_TARGET="${MIXLI_RESTORE_TARGET:-}" \
    MIXLI_TEST_COMMAND_FAIL="${MIXLI_TEST_COMMAND_FAIL:-0}" \
    MIXLI_POSTGRES_IMAGE='mixli-postgres:test' \
    "$REPO_ROOT/ops/production/bin/restore-verify.sh" "$@"
}

restore_verify_with_container_shims() {
  env \
    PATH="$TEST_ROOT/bin:$PATH" \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_RESTORE_TARGET="$1" \
    MIXLI_PGBACKREST_CONFIG="$TEST_ROOT/pgbackrest.conf" \
    MIXLI_POSTGRES_IMAGE='mixli-postgres:b5098ec72c804b6df97a7017681ea17b9843d73c' \
    "$REPO_ROOT/ops/production/bin/restore-verify.sh"
}

@test "production restore verification requires an exact PostgreSQL SHA image" {
  local target="$TEST_ROOT/restore-tests/pinned-image"

  run env \
    PATH="$TEST_ROOT/bin:$PATH" \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_RESTORE_TARGET="$target" \
    MIXLI_PGBACKREST_CONFIG="$TEST_ROOT/pgbackrest.conf" \
    "$REPO_ROOT/ops/production/bin/restore-verify.sh"
  [ "$status" -eq 64 ]

  run env \
    PATH="$TEST_ROOT/bin:$PATH" \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_RESTORE_TARGET="$target" \
    MIXLI_PGBACKREST_CONFIG="$TEST_ROOT/pgbackrest.conf" \
    MIXLI_POSTGRES_IMAGE='mixli-postgres:test' \
    "$REPO_ROOT/ops/production/bin/restore-verify.sh"
  [ "$status" -eq 64 ]
}

@test "restore verification service loads the pinned production environment" {
  grep -Fxq 'EnvironmentFile=/etc/mixli/env/production.env' \
    "$REPO_ROOT/ops/production/systemd/mixli-restore-verify.service"
}

@test "backup type is limited to full, incr, or check" {
  run backup differential
  [ "$status" -eq 64 ]
}

@test "full and incremental backups target both repositories then run one global check" {
  run backup full
  [ "$status" -eq 0 ]
  grep -q -- '--repo=1 --type=full backup' "$COMMAND_LOG"
  grep -q -- '--repo=2 --type=full backup' "$COMMAND_LOG"
  [ "$(grep -Fxc 'check' "$COMMAND_LOG")" -eq 1 ]
  ! grep -Eq -- '--repo=[12] check' "$COMMAND_LOG"

  : >"$COMMAND_LOG"
  run backup incr
  [ "$status" -eq 0 ]
  grep -q -- '--repo=1 --type=incr backup' "$COMMAND_LOG"
  grep -q -- '--repo=2 --type=incr backup' "$COMMAND_LOG"
}

@test "backup operations use a nonblocking exclusive lock" {
  exec 8>"$TEST_ROOT/locks/backup.lock"
  flock -n 8
  run backup check
  exec 8>&-
  [ "$status" -eq 75 ]
}

@test "pgBackRest failures propagate and do not emit success metrics" {
  MIXLI_TEST_COMMAND_FAIL=1 run backup check
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/metrics/pgbackrest.prom" ]
}

@test "successful backup and check emit Prometheus timestamps atomically" {
  run backup full
  [ "$status" -eq 0 ]
  grep -Eq '^mixli_pgbackrest_last_backup_success_timestamp [0-9]+$' "$TEST_ROOT/metrics/pgbackrest.prom"
  grep -Eq '^mixli_pgbackrest_last_check_success_timestamp [0-9]+$' "$TEST_ROOT/metrics/pgbackrest.prom"
}

@test "restore verification refuses the production data directory" {
  MIXLI_RESTORE_TARGET="$TEST_ROOT/data/postgres" run restore_verify
  [ "$status" -eq 64 ]
}

@test "restore verification is isolated, cleans success, and emits a timestamp" {
  local target="$TEST_ROOT/restore-tests/20260828T010203Z"
  MIXLI_RESTORE_TARGET="$target" run restore_verify
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
  grep -Eq '^mixli_pgbackrest_last_restore_verify_success_timestamp [0-9]+$' "$TEST_ROOT/metrics/restore-verify.prom"
}

@test "restore verification preserves a failed isolated target for investigation" {
  local target="$TEST_ROOT/restore-tests/failed-case"
  MIXLI_RESTORE_TARGET="$target" MIXLI_TEST_COMMAND_FAIL=1 run restore_verify
  [ "$status" -ne 0 ]
  [ -d "$target" ]
  [ ! -e "$TEST_ROOT/metrics/restore-verify.prom" ]
}

@test "repo2 restore stages root-only pgBackRest config before dropping to postgres" {
  local target="$TEST_ROOT/restore-tests/staged-restore"
  run restore_verify_with_container_shims "$target"
  [ "$status" -eq 0 ]

  local restore_command
  restore_command="$(sed -n '1p' "$COMMAND_LOG")"
  [[ "$restore_command" != *'--user'* ]]
  [[ "$restore_command" == *"$TEST_ROOT/pgbackrest.conf:/run/mixli-secrets/pgbackrest.conf:ro"* ]]
  [[ "$restore_command" != *':/etc/pgbackrest/pgbackrest.conf'* ]]
  [[ "$restore_command" == *'-e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1'* ]]
  [[ "$restore_command" == *'mixli-postgres:b5098ec72c804b6df97a7017681ea17b9843d73c gosu postgres pgbackrest --stanza=mixli --repo=2 --pg1-path=/var/lib/postgresql/18/docker restore'* ]]
}

@test "isolated PostgreSQL boot keeps staged pgBackRest config and strict S3 validation" {
  local target="$TEST_ROOT/restore-tests/staged-boot"
  run restore_verify_with_container_shims "$target"
  [ "$status" -eq 0 ]

  local boot_command
  boot_command="$(grep '^run -d ' "$COMMAND_LOG")"
  [[ "$boot_command" == *'--network none'* ]]
  [[ "$boot_command" == *"$TEST_ROOT/pgbackrest.conf:/run/mixli-secrets/pgbackrest.conf:ro"* ]]
  [[ "$boot_command" != *':/etc/pgbackrest/pgbackrest.conf'* ]]
  [[ "$boot_command" == *'-e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1'* ]]
  [[ "$boot_command" == *'mixli-postgres:b5098ec72c804b6df97a7017681ea17b9843d73c -c archive_mode=off -c shared_buffers=128MB'* ]]
}
