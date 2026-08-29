#!/usr/bin/env bats

setup() {
  IMAGE="${MIXLI_POSTGRES_IMAGE:-mixli-postgres:test}"
  STAGED_CONFIG=/run/mixli-secrets/pgbackrest.conf
  RUNTIME_CONFIG=/etc/pgbackrest/pgbackrest.conf
  CREDENTIAL_MARKER=MIXLI_TEST_CREDENTIAL_DO_NOT_LOG
  TEST_ROOT="$(mktemp -d)"
  SOURCE_CONFIG="$TEST_ROOT/pgbackrest.conf"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_valid_config() {
  cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
start-fast=y

# Synthetic credential marker used only to prove diagnostics do not leak values.
# $CREDENTIAL_MARKER
[mixli]
pg1-path=/var/lib/postgresql/18/docker
EOF
}

set_source_metadata() {
  local owner="$1"
  local mode="$2"

  docker run --rm -v "$TEST_ROOT:/fixture" alpine:3.22 \
    sh -ceu 'chown "$1" /fixture/pgbackrest.conf; chmod "$2" /fixture/pgbackrest.conf' \
    -- "$owner" "$mode"
}

assert_private_failure() {
  local expected="$1"

  [ "$status" -ne 0 ]
  [ "$output" = "$expected" ]
  [[ "$output" != *"$CREDENTIAL_MARKER"* ]]
}

@test "wrapper rejects a missing staged pgBackRest configuration without leaking values" {
  run docker run --rm "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration is missing"
}

@test "wrapper rejects an empty staged pgBackRest configuration without leaking values" {
  : >"$SOURCE_CONFIG"
  set_source_metadata 0:0 0600

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration must be a non-empty regular file"
}

@test "wrapper rejects a non-root-owned staged pgBackRest configuration without leaking values" {
  write_valid_config
  set_source_metadata 12345:12345 0600

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration must be owned by root:root"
}

@test "wrapper rejects an over-permissive staged pgBackRest configuration without leaking values" {
  write_valid_config
  set_source_metadata 0:0 0644

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration must have mode 0600"
}

@test "wrapper rejects an incomplete staged pgBackRest configuration without leaking values" {
  cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest/$CREDENTIAL_MARKER
EOF
  set_source_metadata 0:0 0600

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
}

@test "wrapper rejects a local-only config when production S3 settings are required" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
}

@test "wrapper creates a private postgres-owned copy and leaves the read-only source unchanged" {
  write_valid_config
  set_source_metadata 0:0 0600
  local source_hash_before source_metadata_before
  source_hash_before="$(sha256sum "$SOURCE_CONFIG")"
  source_metadata_before="$(stat -c '%u:%g:%a:%s' "$SOURCE_CONFIG")"

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" \
    sh -ceu '
      test "$(sha256sum "$1" | cut -d " " -f 1)" = "$(sha256sum "$2" | cut -d " " -f 1)"
      stat -c "%U:%G %a" "$2"
    ' -- "$STAGED_CONFIG" "$RUNTIME_CONFIG"

  [ "$status" -eq 0 ]
  [ "$output" = "postgres:postgres 600" ]
  [ "$(sha256sum "$SOURCE_CONFIG")" = "$source_hash_before" ]
  [ "$(stat -c '%u:%g:%a:%s' "$SOURCE_CONFIG")" = "$source_metadata_before" ]
}

@test "wrapper delegates arguments unchanged and preserves the upstream exit status" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" \
    sh -ceu '
      test "$1" = "argument with spaces"
      test "$2" = "--literal-option"
      exit 37
    ' -- "argument with spaces" "--literal-option"

  [ "$status" -eq 37 ]
  [ -z "$output" ]
}
