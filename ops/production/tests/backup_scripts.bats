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
    "$REPO_ROOT/ops/production/bin/restore-verify.sh" "$@"
}

@test "backup type is limited to full, incr, or check" {
  run backup differential
  [ "$status" -eq 64 ]
}

@test "full and incremental backups target both repositories and then check both" {
  run backup full
  [ "$status" -eq 0 ]
  grep -q -- '--repo=1 --type=full backup' "$COMMAND_LOG"
  grep -q -- '--repo=2 --type=full backup' "$COMMAND_LOG"
  grep -q -- '--repo=1 check' "$COMMAND_LOG"
  grep -q -- '--repo=2 check' "$COMMAND_LOG"

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
