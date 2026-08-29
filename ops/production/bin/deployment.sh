#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SHA="${1-}"
readonly TEST_MODE="${MIXLI_DEPLOY_TEST_MODE:-0}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly LOCK_FILE="${MIXLI_LOCK_FILE:-/run/lock/mixli-deploy.lock}"
readonly BACKUP_LOCK_FILE="${MIXLI_BACKUP_LOCK_FILE:-/run/lock/mixli-backup.lock}"
readonly COMPOSE_FILE="${MIXLI_COMPOSE_FILE:-${MIXLI_ROOT:-/srv/mixli}/runtime/compose.yaml}"
readonly ENV_FILE="${MIXLI_ENV_FILE:-/etc/mixli/env/production.env}"
readonly CI_RUNNER="${MIXLI_CI_RUNNER:-/opt/mixli/bin/server-ci.sh}"
readonly RELEASES="$ROOT/releases"
readonly BUILDS="$ROOT/builds"
readonly RUNTIME="$ROOT/runtime"
readonly STATE="$ROOT/state"
readonly LOG_DIR="$ROOT/log"
readonly EVENTS="$LOG_DIR/deploy-events.log"
readonly DRAIN_SECONDS="${MIXLI_DRAIN_SECONDS:-30}"
readonly POSTGRES_CI_IMAGE="mixli-postgres-ci:$SHA"
readonly POSTGRES_IMAGE="mixli-postgres:$SHA"

switched=0
previous_web=''
upstream_backup=''
env_backup=''
env_changed=0
compose_backup=''
compose_changed=0
compose_had_previous=0
target_pool=''
had_upstream=0
postgres_ci_retained=0

builder_git() {
  runuser -u mixli-build -- git "$@"
}

log_event() {
  install -d -m 0750 "$LOG_DIR"
  printf '%s\n' "$1" >>"$EVENTS"
}

fail_if_requested() {
  local stage="$1"
  if [[ "$TEST_MODE" == '1' && "${MIXLI_TEST_FAIL_STAGE:-}" == "$stage" ]]; then
    log_event "failed:$stage"
    return 1
  fi
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

json_field() {
  local file="$1" field="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/.*\"$field\":\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1
}

write_json_atomic() {
  local destination="$1" content="$2" temporary
  temporary="$(dirname "$destination")/.$(basename "$destination").$$.tmp"
  printf '%s\n' "$content" >"$temporary"
  mv -fT "$temporary" "$destination"
}

write_upstream() {
  local pool="$1" temporary="$RUNTIME/.api-upstream.$$.conf"
  cat >"$temporary" <<EOF
upstream mixli_api {
    least_conn;
    server api-${pool}-1:8080 max_fails=3 fail_timeout=10s;
    server api-${pool}-2:8080 max_fails=3 fail_timeout=10s;
    keepalive 64;
}
EOF
  mv -fT "$temporary" "$RUNTIME/api-upstream.conf"
}

switch_web() {
  local release="$1" temporary="$ROOT/.current.$$.tmp"
  ln -s "$release" "$temporary"
  mv -fT "$temporary" "$ROOT/current"
}

reload_nginx() {
  fail_if_requested nginx
  [[ "$TEST_MODE" == '1' ]] && return 0
  compose up -d --no-deps nginx
  compose exec -T nginx nginx -t
  compose exec -T nginx nginx -s reload
}

restore_runtime_env() {
  local temporary="${ENV_FILE}.$$.rollback"
  [[ "$env_changed" == '1' && -n "$env_backup" && -f "$env_backup" ]] || return 0
  cp --preserve=mode,ownership,timestamps "$env_backup" "$temporary"
  mv -fT "$temporary" "$ENV_FILE"
}

set_env_value() {
  local key="$1" value="$2" temporary="${ENV_FILE}.$$.tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" >"$temporary"
  chmod --reference="$ENV_FILE" "$temporary"
  chown --reference="$ENV_FILE" "$temporary"
  mv -fT "$temporary" "$ENV_FILE"
}

persist_runtime_images() {
  local current_sha="$1"
  env_backup="$RUNTIME/.production.env.previous.$$"
  cp --preserve=mode,ownership,timestamps "$ENV_FILE" "$env_backup"
  env_changed=1

  set_env_value MIXLI_POSTGRES_IMAGE "$POSTGRES_IMAGE"

  if [[ -z "$current_sha" ]]; then
    set_env_value MIXLI_API_BLUE_IMAGE "mixli-api:$SHA"
    set_env_value MIXLI_API_GREEN_IMAGE "mixli-api:$SHA"
    set_env_value MIXLI_API_BLUE_RELEASE_SHA "$SHA"
    set_env_value MIXLI_API_GREEN_RELEASE_SHA "$SHA"
  else
    set_env_value "MIXLI_API_${target_pool^^}_IMAGE" "mixli-api:$SHA"
    set_env_value "MIXLI_API_${target_pool^^}_RELEASE_SHA" "$SHA"
  fi
}

cleanup_postgres_ci_image() {
  local cleanup_status
  [[ "$postgres_ci_retained" == '1' ]] || return 0
  if docker image rm --force "$POSTGRES_CI_IMAGE" >/dev/null 2>&1; then
    postgres_ci_retained=0
    return 0
  else
    cleanup_status=$?
  fi
  printf 'Failed to remove exact CI image tag %s.\n' "$POSTGRES_CI_IMAGE" >&2
  log_event "postgres-ci-cleanup-failed:$SHA" || true
  return "$cleanup_status"
}

promote_postgres_image() {
  local ci_image_id production_image_id
  ci_image_id="$(docker image inspect --format '{{.Id}}' "$POSTGRES_CI_IMAGE")"
  [[ -n "$ci_image_id" ]]

  if production_image_id="$(docker image inspect --format '{{.Id}}' "$POSTGRES_IMAGE" 2>/dev/null)"; then
    [[ "$production_image_id" == "$ci_image_id" ]]
  else
    docker image tag "$ci_image_id" "$POSTGRES_IMAGE"
    production_image_id="$(docker image inspect --format '{{.Id}}' "$POSTGRES_IMAGE")"
    [[ "$production_image_id" == "$ci_image_id" ]]
  fi

  cleanup_postgres_ci_image
}

restore_runtime_compose() {
  local temporary="${COMPOSE_FILE}.$$.rollback"
  [[ "$compose_changed" == '1' ]] || return 0
  if [[ "$compose_had_previous" == '1' && -f "$compose_backup" ]]; then
    cp --preserve=mode,ownership,timestamps "$compose_backup" "$temporary"
    mv -fT "$temporary" "$COMPOSE_FILE"
  else
    rm -f -- "$COMPOSE_FILE"
  fi
}

persist_runtime_compose() {
  local source="$BUILDS/$SHA/ops/production/compose.yaml" temporary="${COMPOSE_FILE}.$$.tmp"
  [[ -f "$source" ]]
  compose_backup="$RUNTIME/.compose.yaml.previous.$$"
  if [[ -f "$COMPOSE_FILE" ]]; then
    cp --preserve=mode,ownership,timestamps "$COMPOSE_FILE" "$compose_backup"
    compose_had_previous=1
  fi
  install -m 0640 "$source" "$temporary"
  mv -fT "$temporary" "$COMPOSE_FILE"
  compose_changed=1
}

rollback_switches() {
  [[ "$switched" == '1' ]] || return 0
  set +e
  if [[ -n "$upstream_backup" && -f "$upstream_backup" ]]; then
    cp "$upstream_backup" "$RUNTIME/.api-upstream.rollback.$$.conf"
    mv -fT "$RUNTIME/.api-upstream.rollback.$$.conf" "$RUNTIME/api-upstream.conf"
  elif [[ "$had_upstream" == '0' ]]; then
    rm -f -- "$RUNTIME/api-upstream.conf"
  fi
  if [[ -n "$previous_web" && -d "$previous_web" ]]; then
    switch_web "$previous_web"
  else
    rm -f -- "$ROOT/current"
  fi
  reload_nginx
  log_event "rollback:$SHA"
}

on_error() {
  local status="$1" line="$2"
  set +e
  rollback_switches
  restore_runtime_compose
  restore_runtime_env
  cleanup_postgres_ci_image
  log_event "deploy-failed:$SHA:line-$line:status-$status"
  exit "$status"
}

validate_root() {
  [[ "$ROOT" == /* && "$ROOT" != '/' && "$RELEASES" == "$ROOT/releases" ]]
}

validate_sha() {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || {
    printf '%s\n' 'deployment.sh requires an exact 40-character lowercase commit SHA.' >&2
    exit 64
  }
}

verify_ancestry() {
  if [[ "$TEST_MODE" == '1' ]]; then
    [[ "${MIXLI_TEST_SHA_ALLOWED:-1}" == '1' ]] || exit 65
    return 0
  fi
  builder_git -C "$REPO" fetch --prune origin main
  builder_git -C "$REPO" merge-base --is-ancestor "$SHA" origin/main || exit 65
}

run_repository_ci() {
  fail_if_requested ci
  if [[ "$TEST_MODE" == '1' ]]; then
    log_event "ci-verified:$SHA"
    postgres_ci_retained=1
    return 0
  fi
  MIXLI_CI_RETAIN_POSTGRES_IMAGE=1 "$CI_RUNNER" "$BUILDS/$SHA" "$SHA"
  postgres_ci_retained=1
  log_event "ci-verified:$SHA"
}

prepare_checkout() {
  local build_dir="$BUILDS/$SHA" actual
  [[ "$TEST_MODE" == '1' ]] && return 0
  if [[ -d "$build_dir/.git" || -f "$build_dir/.git" ]]; then
    actual="$(builder_git -C "$build_dir" rev-parse HEAD)"
    [[ "$actual" == "$SHA" ]] || exit 66
    return 0
  fi
  [[ ! -e "$build_dir" ]] || exit 66
  builder_git -C "$REPO" worktree add --detach "$build_dir" "$SHA"
}

build_release() {
  local build_dir="$BUILDS/$SHA" release_dir="$RELEASES/$SHA" built_at
  fail_if_requested build
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  install -d -m 0750 "$release_dir/web"

  if [[ "$TEST_MODE" == '1' ]]; then
    printf 'web:%s\n' "$SHA" >"$release_dir/web/index.html"
  else
    cp -a "$build_dir/apps/mosaic_app/build/web/." "$release_dir/web/"
  fi

  write_json_atomic "$release_dir/release.json" \
    "{\"sha\":\"$SHA\",\"built_at\":\"$built_at\"}"
  log_event "built:$SHA"
}

validate_runtime_compose() {
  [[ "$TEST_MODE" == '1' ]] || compose config --quiet
}

prepare_database() {
  if [[ "$TEST_MODE" == '1' ]]; then
    log_event 'database-ready'
    return 0
  fi

  compose up -d --no-deps postgres
  local attempt container_id
  for ((attempt = 1; attempt <= 60; attempt++)); do
    container_id="$(compose ps -q postgres)"
    if [[ -n "$container_id" && "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" == 'healthy' ]]; then
      compose exec -T --user postgres postgres pgbackrest --stanza=mixli stanza-create
      log_event 'database-ready'
      return 0
    fi
    sleep 2
  done
  return 1
}

backup_and_migrate() {
  local current_sha="$1" backup_type='incr'
  exec 7>"$BACKUP_LOCK_FILE"
  flock -n 7 || return 75
  fail_if_requested migration
  [[ "$TEST_MODE" == '1' ]] && {
    log_event "migrated:$SHA"
    flock -u 7
    exec 7>&-
    return 0
  }
  [[ -n "$current_sha" ]] || backup_type='full'
  compose exec -T --user postgres postgres pgbackrest --stanza=mixli check
  compose exec -T --user postgres postgres pgbackrest --stanza=mixli --type="$backup_type" backup

  if [[ "$target_pool" == 'blue' ]]; then
    MIXLI_API_BLUE_IMAGE="mixli-api:$SHA" MIXLI_API_BLUE_RELEASE_SHA="$SHA" \
      compose run --rm --no-deps api-blue-1 node dist/db/migrate.js up
  else
    MIXLI_API_GREEN_IMAGE="mixli-api:$SHA" MIXLI_API_GREEN_RELEASE_SHA="$SHA" \
      compose run --rm --no-deps api-green-1 node dist/db/migrate.js up
  fi
  flock -u 7
  exec 7>&-
  log_event "migrated:$SHA"
}

start_candidate() {
  local service_one="api-${target_pool}-1" service_two="api-${target_pool}-2"
  [[ "$TEST_MODE" == '1' ]] && return 0
  if [[ "$target_pool" == 'blue' ]]; then
    MIXLI_API_BLUE_IMAGE="mixli-api:$SHA" MIXLI_API_BLUE_RELEASE_SHA="$SHA" \
      compose up -d --no-deps "$service_one" "$service_two"
  else
    MIXLI_API_GREEN_IMAGE="mixli-api:$SHA" MIXLI_API_GREEN_RELEASE_SHA="$SHA" \
      compose up -d --no-deps "$service_one" "$service_two"
  fi
}

container_is_ready() {
  local service="$1" container_id
  container_id="$(compose ps -q "$service")"
  [[ -n "$container_id" ]]
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" == 'healthy' ]]
}

wait_for_candidate() {
  local attempt consecutive=0 service_one="api-${target_pool}-1" service_two="api-${target_pool}-2"
  fail_if_requested readiness

  if [[ "$TEST_MODE" == '1' ]]; then
    for consecutive in 1 2 3 4 5; do
      log_event "ready:$target_pool:$consecutive"
    done
    return 0
  fi

  for ((attempt = 1; attempt <= 60; attempt++)); do
    if container_is_ready "$service_one" && container_is_ready "$service_two"; then
      consecutive=$((consecutive + 1))
      log_event "ready:$target_pool:$consecutive"
      [[ "$consecutive" -ge 5 ]] && return 0
    else
      consecutive=0
    fi
    sleep 2
  done
  return 1
}

smoke_release() {
  fail_if_requested public-smoke
  [[ "$TEST_MODE" == '1' ]] && return 0
  curl --fail --silent --show-error --max-time 10 \
    --resolve api.mixli.app:443:127.0.0.1 https://api.mixli.app/ready >/dev/null
  curl --fail --silent --show-error --max-time 10 \
    --resolve mixli.app:443:127.0.0.1 https://mixli.app/ >/dev/null
  curl --fail --silent --show-error --max-time 15 https://api.mixli.app/ready >/dev/null
  curl --fail --silent --show-error --max-time 15 https://mixli.app/ >/dev/null
}

stop_old_pool() {
  local old_pool="$1"
  [[ "$DRAIN_SECONDS" =~ ^[0-9]+$ && "$DRAIN_SECONDS" -le 90 ]]
  [[ "$DRAIN_SECONDS" -eq 0 ]] || sleep "$DRAIN_SECONDS"
  [[ "$TEST_MODE" == '1' || -z "$old_pool" ]] && return 0
  compose stop -t 30 "api-${old_pool}-1" "api-${old_pool}-2"
}

record_success() {
  local old_current="$1" old_pool="$2" deployed_at principal current_json previous_json
  deployed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  principal="$(printf '%s' "${SUDO_USER:-${USER:-unknown}}" | tr -cd 'A-Za-z0-9_.@-')"
  current_json="{\"sha\":\"$SHA\",\"pool\":\"$target_pool\",\"deployed_at\":\"$deployed_at\",\"initiator\":\"$principal\"}"
  previous_json="{\"sha\":\"$old_current\",\"pool\":\"$old_pool\"}"
  [[ -z "$old_current" ]] || write_json_atomic "$STATE/previous.json" "$previous_json"
  write_json_atomic "$STATE/current.json" "$current_json"
  log_event "deployed:$SHA:$target_pool"
}

remove_release_image_tag() {
  local image="$1" image_ids lookup_status
  if image_ids="$(docker image ls --quiet --no-trunc "$image")"; then
    :
  else
    lookup_status=$?
    printf 'Failed to query exact release image tag %s.\n' "$image" >&2
    return "$lookup_status"
  fi
  if [[ -z "$image_ids" ]]; then
    return 0
  fi
  docker image rm --force "$image"
}

prune_releases() {
  local current_sha="$1" previous_sha="$2" dir sha kept=0

  while IFS= read -r dir; do
    [[ -n "$dir" && "$dir" == "$RELEASES"/* && -d "$dir" ]] || continue
    sha="$(basename "$dir")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
    if [[ "$sha" == "$current_sha" || "$sha" == "$previous_sha" ]]; then
      continue
    fi
    kept=$((kept + 1))
    if [[ "$kept" -gt 5 ]]; then
      remove_release_image_tag "mixli-api:$sha"
      remove_release_image_tag "mixli-postgres:$sha"
      rm -rf -- "$dir"
    fi
  done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

main() {
  local current_sha current_pool
  validate_sha
  validate_root || exit 64
  install -d -m 0750 "$(dirname "$LOCK_FILE")" "$(dirname "$BACKUP_LOCK_FILE")" "$RELEASES" "$RUNTIME" "$STATE" "$LOG_DIR"
  if [[ "$TEST_MODE" == '1' ]]; then
    install -d -m 0750 "$BUILDS"
  else
    install -d -o mixli-build -g mixli-build -m 0750 "$BUILDS"
  fi
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 75
  trap 'on_error $? $LINENO' ERR

  verify_ancestry
  prepare_checkout
  run_repository_ci
  current_sha="$(json_field "$STATE/current.json" sha)"
  current_pool="$(json_field "$STATE/current.json" pool)"
  if [[ "$current_pool" == 'blue' ]]; then
    target_pool='green'
  else
    target_pool='blue'
  fi

  build_release
  promote_postgres_image
  persist_runtime_compose
  persist_runtime_images "$current_sha"
  validate_runtime_compose
  prepare_database
  backup_and_migrate "$current_sha"
  start_candidate
  wait_for_candidate

  upstream_backup="$RUNTIME/.api-upstream.previous.$$"
  if [[ -f "$RUNTIME/api-upstream.conf" ]]; then
    had_upstream=1
    cp "$RUNTIME/api-upstream.conf" "$upstream_backup"
  fi
  previous_web="$(readlink -f "$ROOT/current" 2>/dev/null || true)"
  switched=1
  write_upstream "$target_pool"
  switch_web "$RELEASES/$SHA"
  reload_nginx

  smoke_release
  prune_releases "$SHA" "$current_sha"
  set_env_value MIXLI_ACTIVE_POOL "$target_pool"
  stop_old_pool "$current_pool"
  record_success "$current_sha" "$current_pool"
  rm -f -- "$upstream_backup"
  rm -f -- "$env_backup"
  rm -f -- "$compose_backup"
  env_changed=0
  compose_changed=0
  switched=0
}

main
