#!/usr/bin/env bats

setup_file() {
  bats_require_minimum_version 1.5.0
}

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
  local blank_key="${2:-}"
  local override_key="${3:-}"
  local override_value="${4:-}"
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
    if [ "$key" = "$omitted_key" ]; then
      continue
    elif [ "$key" = "$blank_key" ]; then
      printf '%s=\n' "$key" >>"$SOURCE_CONFIG"
    elif [ "$key" = "$override_key" ]; then
      printf '%s=%s\n' "$key" "$override_value" >>"$SOURCE_CONFIG"
    else
      printf '%s\n' "$setting" >>"$SOURCE_CONFIG"
    fi
  done
  cat >>"$SOURCE_CONFIG" <<'EOF'

[mixli]
pg1-path=/var/lib/postgresql/18/docker
EOF
}

write_local_config_missing() {
  local missing="$1"

  rm -f "$SOURCE_CONFIG"
  case "$missing" in
    global)
      cat >"$SOURCE_CONFIG" <<EOF
# [global]
[wrong-section]
repo1-path=/var/lib/pgbackrest
# $CREDENTIAL_MARKER
[mixli]
pg1-path=/var/lib/postgresql/18/docker
EOF
      ;;
    repo1-path)
      cat >"$SOURCE_CONFIG" <<EOF
[global]
# repo1-path=/var/lib/pgbackrest/$CREDENTIAL_MARKER
[wrong-section]
repo1-path=/var/lib/pgbackrest
[mixli]
pg1-path=/var/lib/postgresql/18/docker
EOF
      ;;
    mixli)
      cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest
# [mixli]
pg1-path=/var/lib/postgresql/18/docker
# $CREDENTIAL_MARKER
EOF
      ;;
    pg1-path)
      cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest
[wrong-section]
pg1-path=/var/lib/postgresql/18/docker
[mixli]
# pg1-path=/var/lib/postgresql/18/docker/$CREDENTIAL_MARKER
EOF
      ;;
    *)
      return 1
      ;;
  esac
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

@test "wrapper rejects a staged symlink before copying it" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    --entrypoint bash \
    -v "$TEST_ROOT:/fixture:ro" \
    "$IMAGE" -Eeuo pipefail -c '
      ln -s /fixture/pgbackrest.conf "$1"
      exec /usr/local/bin/docker-entrypoint-mixli.sh true
    ' -- "$STAGED_CONFIG"

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration must be a non-empty regular file"
}

@test "wrapper rejects a non-regular staged configuration before copying it" {
  run docker run --rm \
    --entrypoint bash \
    "$IMAGE" -Eeuo pipefail -c '
      mkdir "$1"
      exec /usr/local/bin/docker-entrypoint-mixli.sh true
    ' -- "$STAGED_CONFIG"

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration must be a non-empty regular file"
}

@test "wrapper rejects non-root invocation before reading the staged configuration" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    --user postgres:postgres \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: wrapper must run as root"
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

@test "wrapper requires each base key in its correct section" {
  local missing

  for missing in global repo1-path mixli pg1-path; do
    write_local_config_missing "$missing"
    set_source_metadata 0:0 0600

    run docker run --rm -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" "$IMAGE" true

    assert_private_failure \
      "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
  done
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

@test "wrapper accepts an explicit disabled strict repo2 toggle" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=0 \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrapper rejects a textual strict repo2 toggle without downgrading validation" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=true \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: MIXLI_PGBACKREST_REQUIRE_REPO2_S3 must be unset, 0, or 1"
}

@test "wrapper rejects a zero-padded strict repo2 toggle without downgrading validation" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=01 \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: MIXLI_PGBACKREST_REQUIRE_REPO2_S3 must be unset, 0, or 1"
}

@test "wrapper rejects a whitespace strict repo2 toggle without downgrading validation" {
  write_valid_config
  set_source_metadata 0:0 0600

  run docker run --rm \
    -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=' ' \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" true

  assert_private_failure \
    "mixli postgres entrypoint: MIXLI_PGBACKREST_REQUIRE_REPO2_S3 must be unset, 0, or 1"
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

@test "wrapper ignores strict repo2 keys placed in the wrong section" {
  local required_key required_value

  while read -r required_key required_value; do
    write_strict_config "$required_key"
    cat >>"$SOURCE_CONFIG" <<EOF

[wrong-section]
$required_key=$required_value
EOF
    set_source_metadata 0:0 0600

    run docker run --rm \
      -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
      -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
      "$IMAGE" true

    assert_private_failure \
      "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
  done <<'EOF'
repo2-type s3
repo2-s3-endpoint offline.invalid
repo2-s3-bucket synthetic-test-bucket
repo2-s3-key MIXLI_TEST_ACCESS_KEY
repo2-s3-key-secret MIXLI_TEST_SECRET_KEY
repo2-cipher-type aes-256-cbc
repo2-cipher-pass MIXLI_TEST_CIPHER_PASS
EOF
}

@test "wrapper rejects blank strict repo2 endpoint bucket credential and passphrase values" {
  local blank_key

  for blank_key in \
    repo2-s3-endpoint \
    repo2-s3-bucket \
    repo2-s3-key \
    repo2-s3-key-secret \
    repo2-cipher-pass; do
    write_strict_config "" "$blank_key"
    set_source_metadata 0:0 0600

    run docker run --rm \
      -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
      -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
      "$IMAGE" true

    assert_private_failure \
      "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
  done
}

@test "wrapper rejects incorrect fixed repo2 type and cipher semantics" {
  local fixed_key invalid_value

  while read -r fixed_key invalid_value; do
    write_strict_config "" "" "$fixed_key" "$invalid_value"
    set_source_metadata 0:0 0600

    run docker run --rm \
      -e MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1 \
      -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
      "$IMAGE" true

    assert_private_failure \
      "mixli postgres entrypoint: staged pgBackRest configuration has invalid required values"
  done <<'EOF'
repo2-type posix
repo2-cipher-type none
EOF
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

@test "wrapper removes same-directory temporary files after content validation fails" {
  cat >"$SOURCE_CONFIG" <<EOF
[global]
repo1-path=/var/lib/pgbackrest/$CREDENTIAL_MARKER
EOF
  set_source_metadata 0:0 0600

  run docker run --rm \
    --entrypoint bash \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    "$IMAGE" -Eeuo pipefail -c '
      set +e
      /usr/local/bin/docker-entrypoint-mixli.sh true
      wrapper_status=$?
      set -e
      test "$wrapper_status" -ne 0
      test -z "$(find /etc/pgbackrest -maxdepth 1 -name ".pgbackrest.conf.tmp.*" -print -quit)"
      exit "$wrapper_status"
    '

  assert_private_failure \
    "mixli postgres entrypoint: staged pgBackRest configuration is missing required keys"
}

@test "wrapper atomically replaces an existing runtime target without leaving temporary files" {
  write_valid_config
  set_source_metadata 0:0 0600
  cat >"$TEST_ROOT/verify-runtime-config" <<'EOF'
#!/bin/sh
set -eu
cmp -s "$1" "$2"
test -z "$(find /etc/pgbackrest -maxdepth 1 -name '.pgbackrest.conf.tmp.*' -print -quit)"
EOF
  chmod 0755 "$TEST_ROOT/verify-runtime-config"

  run docker run --rm \
    --entrypoint bash \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    -v "$TEST_ROOT/verify-runtime-config:/test-bin/verify-runtime-config:ro" \
    "$IMAGE" -Eeuo pipefail -c '
      printf "%s\n" stale-runtime-configuration >"$1"
      exec /usr/local/bin/docker-entrypoint-mixli.sh \
        /test-bin/verify-runtime-config "$2" "$1"
    ' -- "$RUNTIME_CONFIG" "$STAGED_CONFIG"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "image keeps staging metadata examples entrypoint and command fail-closed" {
  run docker image inspect \
    --format '{{json .Config.Entrypoint}}|{{json .Config.Cmd}}' \
    "$IMAGE"

  [ "$status" -eq 0 ]
  [ "$output" = \
    '["/usr/local/bin/docker-entrypoint-mixli.sh"]|["postgres","-c","config_file=/etc/postgresql/postgresql.conf"]' ]

  run docker run --rm --entrypoint sh "$IMAGE" -ceu '
    test "$(stat -c "%U:%G:%a" /run/mixli-secrets)" = "root:root:700"
    test "$(stat -c "%U:%G:%a" /usr/local/share/mixli/pgbackrest.conf.example)" = "root:root:644"
    test "$(stat -c "%U:%G:%a" /usr/local/bin/docker-entrypoint-mixli.sh)" = "root:root:755"
    test -f /usr/local/share/mixli/pgbackrest.conf.example
    test ! -e /etc/pgbackrest/pgbackrest.conf
    test -z "$(find /etc/pgbackrest -maxdepth 1 -name "pgbackrest.conf.example" -print -quit)"
  '

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrapper restores the incoming umask before delegating" {
  write_valid_config
  set_source_metadata 0:0 0600
  cat >"$TEST_ROOT/verify-umask" <<'EOF'
#!/bin/sh
set -eu
test "$(umask)" = "$1"
EOF
  chmod 0755 "$TEST_ROOT/verify-umask"

  run docker run --rm \
    --entrypoint sh \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    -v "$TEST_ROOT/verify-umask:/test-bin/verify-umask:ro" \
    "$IMAGE" -ceu '
      umask 0027
      exec /usr/local/bin/docker-entrypoint-mixli.sh /test-bin/verify-umask 0027
    '

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrapper delegates leading PostgreSQL options through the upstream entrypoint and preserves its exit status" {
  write_valid_config
  set_source_metadata 0:0 0600
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pgdata"
  printf '%s\n' 18 >"$TEST_ROOT/pgdata/PG_VERSION"
  cat >"$TEST_ROOT/bin/postgres" <<'EOF'
#!/bin/sh
set -eu
test "$1" = -c
test "$2" = shared_buffers=64MB
test "$3" = -c
test "$4" = max_connections=17
exit 37
EOF
  chmod 0755 "$TEST_ROOT/bin/postgres"

  run -37 docker run --rm \
    -e PATH=/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e PGDATA=/var/lib/postgresql/upstream-probe \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    -v "$TEST_ROOT/bin:/test-bin:ro" \
    -v "$TEST_ROOT/pgdata:/var/lib/postgresql/upstream-probe" \
    "$IMAGE" -c shared_buffers=64MB -c max_connections=17

  [ "$status" -eq 37 ]
  [[ "$output" != *"$CREDENTIAL_MARKER"* ]]
}

@test "wrapper delegates exact arguments to the upstream entrypoint path and preserves its exit status" {
  write_valid_config
  set_source_metadata 0:0 0600
  cat >"$TEST_ROOT/upstream-entrypoint" <<'EOF'
#!/bin/sh
set -eu
test "$#" -eq 3
test "$1" = "argument with spaces"
test "$2" = "--literal-option"
test "$3" = "final-argument"
exit 37
EOF
  chmod 0755 "$TEST_ROOT/upstream-entrypoint"

  run -37 docker run --rm \
    --entrypoint /usr/local/bin/docker-entrypoint-mixli.sh \
    -v "$SOURCE_CONFIG:$STAGED_CONFIG:ro" \
    -v "$TEST_ROOT/upstream-entrypoint:/usr/local/bin/docker-entrypoint.sh:ro" \
    "$IMAGE" "argument with spaces" "--literal-option" "final-argument"

  [ "$status" -eq 37 ]
  [[ "$output" != *"$CREDENTIAL_MARKER"* ]]
}
