#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  VERIFY="$REPO_ROOT/ops/production/bin/verify-production.sh"
}
@test "production verifier exposes origin and public modes" {
  run env MIXLI_VERIFY_TEST_MODE=1 "$VERIFY" --origin
  [ "$status" -eq 0 ]
  [[ "$output" == *'PASS command availability'* ]]
  [[ "$output" == *'PASS HTTP and TLS'* ]]
  [[ "$output" == *'PASS API release header'* ]]
  [[ "$output" == *'PASS guest catalog'* ]]
  [[ "$output" == *'PASS container health'* ]]
  [[ "$output" == *'PASS migration status'* ]]
  [[ "$output" == *'PASS backup and WAL freshness'* ]]
  [[ "$output" == *'PASS firewall policy'* ]]
  [[ "$output" == *'8 passed, 0 failed'* ]]

  run env MIXLI_VERIFY_TEST_MODE=1 "$VERIFY" --public
  [ "$status" -eq 0 ]
  [[ "$output" == *'3 passed, 0 failed'* ]]
}

@test "production verifier rejects unsupported modes" {
  run "$VERIFY" --unsafe
  [ "$status" -eq 64 ]
  [[ "$output" == *'Usage: verify-production.sh {--origin|--public}'* ]]
}

@test "production verifier returns non-zero when an assertion fails" {
  run env MIXLI_VERIFY_TEST_MODE=1 MIXLI_VERIFY_FAIL_CHECK='container health' \
    "$VERIFY" --origin
  [ "$status" -ne 0 ]
  [[ "$output" == *'FAIL container health'* ]]
  [[ "$output" == *'7 passed, 1 failed'* ]]
}

@test "origin verifier requires six guest catalog topics" {
  check="$(sed -n '/^check_guest_catalog()/,/^}/p' "$VERIFY")"
  [[ "$check" == *"curl_endpoint api.mixli.app '/v1/topics?limit=6'"* ]]
  [[ "$check" == *"jq '.topics | length'"* ]]
}

@test "production verifier never emits environment or secret values" {
  run env MIXLI_VERIFY_TEST_MODE=1 \
    DATABASE_URL='postgres://secret-value' \
    MIXLI_VERIFY_FAIL_CHECK='migration status' \
    "$VERIFY" --origin
  [ "$status" -ne 0 ]
  [[ "$output" != *'secret-value'* ]]
  [[ "$output" != *'DATABASE_URL'* ]]
}

@test "production verifier uses the pgBackRest global check command" {
  check="$(sed -n '/^check_backup_wal()/,/^}/p' "$VERIFY")"
  [[ "$check" == *'postgres pgbackrest --stanza=mixli check'* ]]
  [[ "$check" != *'--repo='* ]]
}

@test "WAL freshness uses the configured database role and database" {
  check="$(sed -n '/^check_backup_wal()/,/^}/p' "$VERIFY")"
  [[ "$check" == *'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'* ]]
}
