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

write_strict_config() {
  local omitted_key="${1:-}"
  local setting key

  rm -f "$SOURCE_CONFIG"
  cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
start-fast=y

# Synthetic credential marker used only to prove diagnostics do not leak values.
# $CREDENTIAL_MARKER
EOF
  for setting in \
    'repo2-type=s3' \
    'repo2-path=/mixli/postgres' \
    'repo2-s3-region=auto' \
    'repo2-s3-uri-style=path' \
    'repo2-s3-endpoint=offline.invalid' \
    'repo2-s3-bucket=synthetic-test-bucket' \
    'repo2-s3-key=MIXLI_TEST_ACCESS_KEY' \
    "repo2-s3-key-secret=$CREDENTIAL_MARKER-secret" \
    'repo2-cipher-type=aes-256-cbc' \
    "repo2-cipher-pass=$CREDENTIAL_MARKER-cipher" \
    'repo2-bundle=y' \
    'repo2-block=y' \
    'repo2-retention-full=2'; do
    key="${setting%%=*}"
    if [ "$key" != "$omitted_key" ]; then
      printf '%s\n' "$setting" >>"$SOURCE_CONFIG"
    fi
  done
  cat >>"$SOURCE_CONFIG" <<'EOF'

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

@test "wrapper accepts a complete synthetic repo2 config in strict mode without network access" {
  write_strict_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrapper requires every strict repo2 credential and encryption field" {
  local required_key

  for required_key in \
    repo2-type \
    repo2-s3-endpoint \
    repo2-s3-bucket \
    repo2-s3-key \
    repo2-s3-key-secret \
    repo2-cipher-type \
    repo2-cipher-pass; do
    write_strict_config "$required_key"
    set_source_metadata 0:0 0600

    run docker run --rm \
      -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
      -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
      "$IMAGE" true

    assert_private_failure \
      "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
  done
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

@test "wrapper delegates leading PostgreSQL options through the upstream entrypoint and preserves its exit status" {
  write_valid_config
  set_source_metadata 0:0 0600
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pgdata"
  printf '%s\n' 18 >"$TEST_ROOT/pgdata/PG_VERSION"
  cat >"$TEST_ROOT/bin/postgres" <<'EOF'
#!/bin/sh
test "$1" = -c
test "$2" = shared_buffers=64MB
test "$3" = -c
test "$4" = max_connections=17
exit 37
EOF
  chmod 0755 "$TEST_ROOT/bin/postgres"

  run docker run --rm \
    -e PATH=/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e PGDATA=/var/lib/postgresql/upstream-probe \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    -v "$TEST_ROOT/bin:/test-bin:ro" \
    -v "$TEST_ROOT/pgdata:/var/lib/postgresql/upstream-probe" \
    "$IMAGE" -c shared_buffers=64MB -c max_connections=17

  [ "$status" -eq 37 ]
  [[ "$output" != *"$CREDENTIAL_MARKER"* ]]
}
