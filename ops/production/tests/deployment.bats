#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  TEST_ROOT="$(mktemp -d)"
  SHA="b5098ec72c804b6df97a7017681ea17b9843d73c"
  OLD_SHA="1111111111111111111111111111111111111111"
  PREVIOUS_SHA="2222222222222222222222222222222222222222"
  mkdir -p "$TEST_ROOT/releases/$OLD_SHA/web" "$TEST_ROOT/releases/$PREVIOUS_SHA/web" \
    "$TEST_ROOT/runtime" "$TEST_ROOT/state" "$TEST_ROOT/log" "$TEST_ROOT/locks" "$TEST_ROOT/repo" \
    "$TEST_ROOT/builds/$SHA/ops/production" "$TEST_ROOT/bin" "$TEST_ROOT/images"
  COMMAND_LOG="$TEST_ROOT/commands.log"
  export COMMAND_LOG MIXLI_TEST_DOCKER_STATE="$TEST_ROOT/images"
  cat >"$TEST_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COMMAND_LOG"
image_file() {
  printf '%s/%s' "$MIXLI_TEST_DOCKER_STATE" "${1//:/__}"
}
if [[ "$1 $2" == 'image inspect' ]]; then
  ref="${@: -1}"
  [[ "$ref" != "${MIXLI_TEST_DOCKER_LOOKUP_FAIL_REF:-}" ]] || exit 43
  file="$(image_file "$ref")"
  [[ -f "$file" ]] || exit 1
  cat "$file"
elif [[ "$1 $2" == 'image ls' ]]; then
  ref="${@: -1}"
  [[ "$ref" != "${MIXLI_TEST_DOCKER_LOOKUP_FAIL_REF:-}" ]] || exit 43
  file="$(image_file "$ref")"
  [[ ! -f "$file" ]] || cat "$file"
elif [[ "$1 $2" == 'image tag' ]]; then
  source="$3"
  target="$4"
  printf '%s\n' "$source" >"$(image_file "$target")"
elif [[ "$1 $2" == 'image rm' ]]; then
  ref="${@: -1}"
  if [[ "$ref" == "${MIXLI_TEST_DOCKER_RM_FAIL_REF:-}" ]]; then
    attempts_file="$MIXLI_TEST_DOCKER_STATE/rm-fail-attempts"
    attempts=0
    [[ ! -f "$attempts_file" ]] || attempts="$(cat "$attempts_file")"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" >"$attempts_file"
    if [[ "$attempts" -le "${MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS:-0}" ]]; then
      exit 42
    fi
  fi
  rm -f -- "$(image_file "$ref")"
fi
SH
  chmod +x "$TEST_ROOT/bin/docker"
  printf '%s\n' 'sha256:ci-postgres-image' \
    >"$TEST_ROOT/images/mixli-postgres-ci__$SHA"
  printf 'compose:%s\n' "$SHA" >"$TEST_ROOT/builds/$SHA/ops/production/compose.yaml"
  printf 'compose:%s\n' "$OLD_SHA" >"$TEST_ROOT/runtime/compose.yaml"
  cat >"$TEST_ROOT/production.env" <<EOF
MIXLI_API_BLUE_IMAGE=mixli-api:$OLD_SHA
MIXLI_API_GREEN_IMAGE=mixli-api:$PREVIOUS_SHA
MIXLI_API_BLUE_RELEASE_SHA=$OLD_SHA
MIXLI_API_GREEN_RELEASE_SHA=$PREVIOUS_SHA
MIXLI_POSTGRES_IMAGE=mixli-postgres:$OLD_SHA
EOF
  printf 'old-web' >"$TEST_ROOT/releases/$OLD_SHA/web/index.html"
  printf 'previous-web' >"$TEST_ROOT/releases/$PREVIOUS_SHA/web/index.html"
  ln -s "$TEST_ROOT/releases/$OLD_SHA" "$TEST_ROOT/current"
  printf '{"sha":"%s","pool":"blue"}\n' "$OLD_SHA" >"$TEST_ROOT/state/current.json"
  printf '{"sha":"%s","pool":"green"}\n' "$PREVIOUS_SHA" >"$TEST_ROOT/state/previous.json"
  printf 'old-upstream\n' >"$TEST_ROOT/runtime/api-upstream.conf"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

deploy() {
  env \
    PATH="$TEST_ROOT/bin:$PATH" \
    MIXLI_DEPLOY_TEST_MODE=1 \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_REPO="$TEST_ROOT/repo" \
    MIXLI_LOCK_FILE="$TEST_ROOT/locks/deploy.lock" \
    MIXLI_BACKUP_LOCK_FILE="$TEST_ROOT/locks/backup.lock" \
    MIXLI_COMPOSE_FILE="$TEST_ROOT/runtime/compose.yaml" \
    MIXLI_ENV_FILE="$TEST_ROOT/production.env" \
    MIXLI_TEST_SHA_ALLOWED="${MIXLI_TEST_SHA_ALLOWED:-1}" \
    MIXLI_TEST_FAIL_STAGE="${MIXLI_TEST_FAIL_STAGE:-}" \
    MIXLI_TEST_DOCKER_RM_FAIL_REF="${MIXLI_TEST_DOCKER_RM_FAIL_REF:-}" \
    MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS="${MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS:-0}" \
    MIXLI_TEST_DOCKER_LOOKUP_FAIL_REF="${MIXLI_TEST_DOCKER_LOOKUP_FAIL_REF:-}" \
    MIXLI_DRAIN_SECONDS=0 \
    "$REPO_ROOT/ops/production/bin/deployment.sh" "$@"
}

@test "rejects anything except an exact lowercase SHA" {
  run deploy 'main; id'
  [ "$status" -eq 64 ]
}

@test "rejects a SHA outside origin main ancestry" {
  MIXLI_TEST_SHA_ALLOWED=0 run deploy "$SHA"
  [ "$status" -eq 65 ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "exclusive lock rejects a concurrent deployment" {
  exec 8>"$TEST_ROOT/locks/deploy.lock"
  flock -n 8
  run deploy "$SHA"
  exec 8>&-
  [ "$status" -eq 75 ]
}

@test "server CI completes before the release is marked built" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  ci_line="$(grep -n "^ci-verified:$SHA$" "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  built_line="$(grep -n "^built:$SHA$" "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  [ -n "$ci_line" ]
  [ "$ci_line" -lt "$built_line" ]
}

@test "server CI failure prevents build migration and switching" {
  MIXLI_TEST_FAIL_STAGE=ci run deploy "$SHA"
  [ "$status" -ne 0 ]
  ! grep -Eq '^(built|migrated|deployed):' "$TEST_ROOT/log/deploy-events.log"
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "selects the inactive pool and requires five consecutive readiness passes" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  grep -q 'server api-green-1:8080' "$TEST_ROOT/runtime/api-upstream.conf"
  grep -q 'server api-green-2:8080' "$TEST_ROOT/runtime/api-upstream.conf"
  [ "$(grep -c '^ready:green:' "$TEST_ROOT/log/deploy-events.log")" -eq 5 ]
}

@test "build failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=build run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
  [ ! -e "$TEST_ROOT/releases/$SHA" ]
  [ ! -e "$TEST_ROOT/images/mixli-postgres__$SHA" ]
  [ ! -e "$TEST_ROOT/images/mixli-postgres-ci__$SHA" ]
  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
}

@test "migration failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=migration run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
  grep -qx "MIXLI_API_GREEN_IMAGE=mixli-api:$PREVIOUS_SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_POSTGRES_IMAGE=mixli-postgres:$OLD_SHA" "$TEST_ROOT/production.env"
  [ "$(cat "$TEST_ROOT/runtime/compose.yaml")" = "compose:$OLD_SHA" ]
}

@test "database readiness precedes every migration" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  database_line="$(grep -n '^database-ready$' "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  migrated_line="$(grep -n "^migrated:$SHA$" "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  [ -n "$database_line" ]
  [ "$database_line" -lt "$migrated_line" ]
}

@test "pre-migration backup cannot overlap a scheduled backup" {
  exec 7>"$TEST_ROOT/locks/backup.lock"
  flock -n 7
  run deploy "$SHA"
  exec 7>&-
  [ "$status" -eq 75 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
}

@test "readiness failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=readiness run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "Nginx validation failure restores the prior on-disk upstream" {
  MIXLI_TEST_FAIL_STAGE=nginx run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "successful deploy atomically switches web and records current and previous releases" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  [ -L "$TEST_ROOT/current" ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$SHA" ]
  grep -q "\"sha\":\"$SHA\"" "$TEST_ROOT/state/current.json"
  grep -q '"pool":"green"' "$TEST_ROOT/state/current.json"
  grep -q "\"sha\":\"$OLD_SHA\"" "$TEST_ROOT/state/previous.json"
  [ -f "$TEST_ROOT/releases/$SHA/release.json" ]
  grep -qx "MIXLI_API_BLUE_IMAGE=mixli-api:$OLD_SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_IMAGE=mixli-api:$SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_RELEASE_SHA=$SHA" "$TEST_ROOT/production.env"
  [ "$(cat "$TEST_ROOT/runtime/compose.yaml")" = "compose:$SHA" ]
}

@test "public smoke failure rolls back both atomic switches" {
  MIXLI_TEST_FAIL_STAGE=public-smoke run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
  grep -q "\"sha\":\"$OLD_SHA\"" "$TEST_ROOT/state/current.json"
  grep -qx "MIXLI_API_GREEN_IMAGE=mixli-api:$PREVIOUS_SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_RELEASE_SHA=$PREVIOUS_SHA" "$TEST_ROOT/production.env"
  [ "$(cat "$TEST_ROOT/runtime/compose.yaml")" = "compose:$OLD_SHA" ]
}

@test "failed first deployment leaves no latent upstream or web link" {
  rm -f "$TEST_ROOT/current" "$TEST_ROOT/runtime/api-upstream.conf" "$TEST_ROOT/runtime/compose.yaml" \
    "$TEST_ROOT/state/current.json" "$TEST_ROOT/state/previous.json"
  MIXLI_TEST_FAIL_STAGE=public-smoke run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/runtime/api-upstream.conf" ]
  [ ! -e "$TEST_ROOT/current" ]
  [ ! -e "$TEST_ROOT/runtime/compose.yaml" ]
  grep -qx "MIXLI_API_BLUE_IMAGE=mixli-api:$OLD_SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_IMAGE=mixli-api:$PREVIOUS_SHA" "$TEST_ROOT/production.env"
}

@test "first successful deployment makes both pools reboot-safe" {
  rm -f "$TEST_ROOT/current" "$TEST_ROOT/runtime/api-upstream.conf" \
    "$TEST_ROOT/state/current.json" "$TEST_ROOT/state/previous.json"

  run deploy "$SHA"

  [ "$status" -eq 0 ]
  grep -qx "MIXLI_API_BLUE_IMAGE=mixli-api:$SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_IMAGE=mixli-api:$SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_BLUE_RELEASE_SHA=$SHA" "$TEST_ROOT/production.env"
  grep -qx "MIXLI_API_GREEN_RELEASE_SHA=$SHA" "$TEST_ROOT/production.env"
}

@test "deployment promotes the retained PostgreSQL image ID and persists its exact SHA" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]

  grep -Fxq "image tag sha256:ci-postgres-image mixli-postgres:$SHA" "$COMMAND_LOG"
  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
  grep -qx "MIXLI_POSTGRES_IMAGE=mixli-postgres:$SHA" "$TEST_ROOT/production.env"
  [ "$(cat "$TEST_ROOT/images/mixli-postgres__$SHA")" = 'sha256:ci-postgres-image' ]
  [ ! -e "$TEST_ROOT/images/mixli-postgres-ci__$SHA" ]
}

@test "deployment accepts an existing identical PostgreSQL SHA tag without retagging" {
  printf '%s\n' 'sha256:ci-postgres-image' \
    >"$TEST_ROOT/images/mixli-postgres__$SHA"

  run deploy "$SHA"
  [ "$status" -eq 0 ]
  ! grep -Fxq "image tag sha256:ci-postgres-image mixli-postgres:$SHA" "$COMMAND_LOG"
  grep -qx "MIXLI_POSTGRES_IMAGE=mixli-postgres:$SHA" "$TEST_ROOT/production.env"
}

@test "deployment rejects a conflicting PostgreSQL SHA tag without overwriting it" {
  printf '%s\n' 'sha256:conflicting-postgres-image' \
    >"$TEST_ROOT/images/mixli-postgres__$SHA"

  run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/images/mixli-postgres__$SHA")" = \
    'sha256:conflicting-postgres-image' ]
  [ -d "$TEST_ROOT/releases/$SHA" ]
  grep -qx "MIXLI_POSTGRES_IMAGE=mixli-postgres:$OLD_SHA" "$TEST_ROOT/production.env"
  [ ! -e "$TEST_ROOT/images/mixli-postgres-ci__$SHA" ]
  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
}

@test "post-promotion CI-tag cleanup failure is retried and fails the deployment" {
  MIXLI_TEST_DOCKER_RM_FAIL_REF="mixli-postgres-ci:$SHA" \
    MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS=2 run deploy "$SHA"

  [ "$status" -ne 0 ]
  [ -e "$TEST_ROOT/images/mixli-postgres-ci__$SHA" ]
  [ "$(grep -Fc "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG")" -eq 2 ]
  grep -qx "postgres-ci-cleanup-failed:$SHA" "$TEST_ROOT/log/deploy-events.log"
  grep -qx "MIXLI_POSTGRES_IMAGE=mixli-postgres:$OLD_SHA" "$TEST_ROOT/production.env"
}

@test "release pruning removes exact image tags before deleting a discoverable release" {
  script="$REPO_ROOT/ops/production/bin/deployment.sh"
  prune="$(sed -n '/^prune_releases()/,/^}/p' "$script")"
  image_cleanup="$(sed -n '/^remove_release_image_tag()/,/^}/p' "$script")"
  [[ "$prune" == *'remove_release_image_tag "mixli-api:$sha"'* ]]
  [[ "$prune" == *'remove_release_image_tag "mixli-postgres:$sha"'* ]]
  [[ "$image_cleanup" == *'docker image ls --quiet --no-trunc "$image"'* ]]
  [[ "$image_cleanup" == *'docker image rm --force "$image"'* ]]

  image_line="$(grep -n 'remove_release_image_tag "mixli-postgres:$sha"' <<<"$prune" | cut -d: -f1)"
  directory_line="$(grep -n 'rm -rf -- "$dir"' <<<"$prune" | cut -d: -f1)"
  [ "$image_line" -lt "$directory_line" ]
}

@test "operational image lookup failure preserves the release for prune retry" {
  local n old prune_sha
  for n in 3 4 5 6 7 8 9; do
    old="$(printf '%040d' "$n")"
    mkdir -p "$TEST_ROOT/releases/$old/web"
    touch -d "2026-08-$((10 + n))" "$TEST_ROOT/releases/$old"
  done
  prune_sha="$(printf '%040d' 4)"

  MIXLI_TEST_DOCKER_LOOKUP_FAIL_REF="mixli-api:$prune_sha" run deploy "$SHA"

  [ "$status" -eq 43 ]
  [ -d "$TEST_ROOT/releases/$prune_sha" ]
  grep -Fxq "image ls --quiet --no-trunc mixli-api:$prune_sha" "$COMMAND_LOG"
}

@test "failed prune keeps its release discoverable and retry tolerates an absent exact tag" {
  local n old prune_sha
  for n in 3 4 5 6 7 8 9; do
    old="$(printf '%040d' "$n")"
    mkdir -p "$TEST_ROOT/releases/$old/web"
    touch -d "2026-08-$((10 + n))" "$TEST_ROOT/releases/$old"
  done
  prune_sha="$(printf '%040d' 4)"
  printf '%s\n' 'sha256:old-api-image' \
    >"$TEST_ROOT/images/mixli-api__$prune_sha"
  printf '%s\n' 'sha256:old-postgres-image' \
    >"$TEST_ROOT/images/mixli-postgres__$prune_sha"

  MIXLI_TEST_DOCKER_RM_FAIL_REF="mixli-postgres:$prune_sha" \
    MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS=1 run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ -d "$TEST_ROOT/releases/$prune_sha" ]
  [ ! -e "$TEST_ROOT/images/mixli-api__$prune_sha" ]
  [ -e "$TEST_ROOT/images/mixli-postgres__$prune_sha" ]

  printf '%s\n' 'sha256:ci-postgres-image' \
    >"$TEST_ROOT/images/mixli-postgres-ci__$SHA"
  MIXLI_TEST_DOCKER_RM_FAIL_REF='' \
    MIXLI_TEST_DOCKER_RM_FAIL_ATTEMPTS=0 run deploy "$SHA"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/releases/$prune_sha" ]
  [ ! -e "$TEST_ROOT/images/mixli-postgres__$prune_sha" ]
}

@test "retention keeps current and previous while bounding other releases" {
  local n old
  for n in 3 4 5 6 7 8 9; do
    old="$(printf '%040d' "$n")"
    mkdir -p "$TEST_ROOT/releases/$old/web"
    touch -d "2026-08-$((10 + n))" "$TEST_ROOT/releases/$old"
  done

  run deploy "$SHA"
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/releases/$SHA" ]
  [ -d "$TEST_ROOT/releases/$OLD_SHA" ]
  [ "$(find "$TEST_ROOT/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 7 ]
}
