#!/usr/bin/env bash
set -Eeuo pipefail

incoming_umask="$(umask)"
readonly incoming_umask
umask 077

readonly STAGED_CONFIG=/run/mixli-secrets/pgbackrest.conf
readonly RUNTIME_CONFIG=/etc/pgbackrest/pgbackrest.conf

temporary_config=''

fail() {
  printf '%s\n' "mixli postgres entrypoint: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$temporary_config" ]]; then
    rm -f -- "$temporary_config"
  fi
}

trap cleanup EXIT

if [[ "$(id -u)" != '0' ]]; then
  fail 'wrapper must run as root'
fi

repo2_s3_required=0
if [[ "${MIXLI_PGBACKREST_REQUIRE_REPO2_S3+set}" == 'set' ]]; then
  case "$MIXLI_PGBACKREST_REQUIRE_REPO2_S3" in
    0) ;;
    1) repo2_s3_required=1 ;;
    *)
      fail 'MIXLI_PGBACKREST_REQUIRE_REPO2_S3 must be unset, 0, or 1'
      ;;
  esac
fi
readonly repo2_s3_required

if [[ ! -e "$STAGED_CONFIG" ]]; then
  fail 'staged pgBackRest configuration is missing'
fi

if [[ -L "$STAGED_CONFIG" || ! -f "$STAGED_CONFIG" || ! -s "$STAGED_CONFIG" ]]; then
  fail 'staged pgBackRest configuration must be a non-empty regular file'
fi

staged_metadata="$(stat -c '%u:%g:%a' -- "$STAGED_CONFIG" 2>/dev/null)" ||
  fail 'staged pgBackRest configuration metadata could not be validated'

if [[ "${staged_metadata%:*}" != '0:0' ]]; then
  fail 'staged pgBackRest configuration must be owned by root:root'
fi

if [[ "${staged_metadata##*:}" != '600' ]]; then
  fail 'staged pgBackRest configuration must have mode 0600'
fi

temporary_config="$(mktemp /etc/pgbackrest/.pgbackrest.conf.tmp.XXXXXX 2>/dev/null)" ||
  fail 'private runtime pgBackRest configuration could not be created'

cp -- "$STAGED_CONFIG" "$temporary_config" 2>/dev/null ||
  fail 'staged pgBackRest configuration could not be copied'
chown postgres:postgres "$temporary_config" 2>/dev/null ||
  fail 'runtime pgBackRest configuration ownership could not be set'
chmod 0600 "$temporary_config" 2>/dev/null ||
  fail 'runtime pgBackRest configuration mode could not be set'

if [[ -L "$temporary_config" || ! -f "$temporary_config" || ! -s "$temporary_config" ]]; then
  fail 'runtime pgBackRest configuration must be a non-empty regular file'
fi

postgres_uid="$(id -u postgres 2>/dev/null)" ||
  fail 'postgres account metadata could not be validated'
postgres_gid="$(id -g postgres 2>/dev/null)" ||
  fail 'postgres account metadata could not be validated'
runtime_metadata="$(stat -c '%u:%g:%a' -- "$temporary_config" 2>/dev/null)" ||
  fail 'runtime pgBackRest configuration metadata could not be validated'

if [[ "$runtime_metadata" != "$postgres_uid:$postgres_gid:600" ]]; then
  fail 'runtime pgBackRest configuration must be owned by postgres:postgres with mode 0600'
fi

validation_status=0
awk -v strict="$repo2_s3_required" '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  {
    sub(/\r$/, "")
    line = trim($0)

    if (line == "" || line ~ /^[#;]/) {
      next
    }

    if (line ~ /^\[[^][]+\]$/) {
      section = trim(substr(line, 2, length(line) - 2))
      if (section == "global") {
        found_global = 1
      } else if (section == "mixli") {
        found_mixli = 1
      }
      next
    }

    separator = index(line, "=")
    if (separator == 0) {
      next
    }

    key = trim(substr(line, 1, separator - 1))
    value = trim(substr(line, separator + 1))

    if (section == "global") {
      if (key == "repo1-path") {
        repo1_path = value
      } else if (key == "repo2-type") {
        repo2_type = value
      } else if (key == "repo2-s3-endpoint") {
        repo2_s3_endpoint = value
      } else if (key == "repo2-s3-bucket") {
        repo2_s3_bucket = value
      } else if (key == "repo2-s3-key") {
        repo2_s3_key = value
      } else if (key == "repo2-s3-key-secret") {
        repo2_s3_key_secret = value
      } else if (key == "repo2-cipher-type") {
        repo2_cipher_type = value
      } else if (key == "repo2-cipher-pass") {
        repo2_cipher_pass = value
      }
    } else if (section == "mixli" && key == "pg1-path") {
      pg1_path = value
    }
  }

  END {
    if (!found_global || repo1_path == "" || !found_mixli || pg1_path == "") {
      exit 10
    }

    if (strict == "1") {
      if (repo2_type == "" || repo2_s3_endpoint == "" ||
          repo2_s3_bucket == "" || repo2_s3_key == "" ||
          repo2_s3_key_secret == "" || repo2_cipher_type == "" ||
          repo2_cipher_pass == "") {
        exit 10
      }

      if (repo2_type != "s3" || repo2_cipher_type != "aes-256-cbc") {
        exit 11
      }
    }
  }
' "$temporary_config" 2>/dev/null || validation_status=$?

case "$validation_status" in
  0) ;;
  10) fail 'staged pgBackRest configuration is missing required keys' ;;
  11) fail 'staged pgBackRest configuration has invalid required values' ;;
  *) fail 'staged pgBackRest configuration could not be validated' ;;
esac

mv -fT -- "$temporary_config" "$RUNTIME_CONFIG" 2>/dev/null ||
  fail 'runtime pgBackRest configuration could not be installed atomically'
temporary_config=''

umask "$incoming_umask"
exec /usr/local/bin/docker-entrypoint.sh "$@"
