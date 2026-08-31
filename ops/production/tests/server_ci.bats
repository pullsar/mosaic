#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  unset MIXLI_CI_RETAIN_RELEASE_IMAGES MIXLI_CI_RETAIN_POSTGRES_IMAGE
  TEST_ROOT="$(mktemp -d)"
  CHECKOUT="$TEST_ROOT/checkout"
  SHA="b5098ec72c804b6df97a7017681ea17b9843d73c"
  COMMAND_LOG="$TEST_ROOT/commands.log"
  mkdir -p "$CHECKOUT" "$TEST_ROOT/bin"
  cat >"$TEST_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMMAND_LOG"
if [[ "$1 $2" == 'image rm' && "${@: -1}" == "${MIXLI_TEST_DOCKER_RM_FAIL_REF:-}" ]]; then
  exit 42
fi
SH
  chmod +x "$TEST_ROOT/bin/docker"
  export COMMAND_LOG
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

run_ci() {
  local engine builder
  engine="${MIXLI_CI_TEST_ENGINE_MODE:-release}"
  builder=mixli-build
  [[ "$engine" != review ]] || builder=mixli-review-build
  PATH="$TEST_ROOT/bin:$PATH" \
    MIXLI_CI_TEST_MODE=1 \
    MIXLI_CI_ENGINE_MODE="$engine" \
    MIXLI_CI_BUILDER_USER="$builder" \
    MIXLI_CI_TEST_FAIL_STAGE="${MIXLI_CI_TEST_FAIL_STAGE:-}" \
    MIXLI_CI_RETAIN_POSTGRES_IMAGE="${MIXLI_CI_RETAIN_POSTGRES_IMAGE:-0}" \
    MIXLI_CI_RETAIN_RELEASE_IMAGES="${MIXLI_CI_RETAIN_RELEASE_IMAGES:-}" \
    MIXLI_TEST_DOCKER_RM_FAIL_REF="${MIXLI_TEST_DOCKER_RM_FAIL_REF:-}" \
    "$REPO_ROOT/ops/production/bin/server-ci.sh" "$@"
}

@test "ordinary CI isolates API test and production candidate images" {
  run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]
  grep -Fxq "image rm --force mixli-api-ci:$SHA" "$COMMAND_LOG"
  grep -Fq 'API_TEST_IMAGE="mixli-api-test:$SHA"' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'API_CI_IMAGE="mixli-api-ci:$SHA"' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
  ! grep -Fq -- '-t "$API_IMAGE"' "$REPO_ROOT/ops/production/bin/server-ci.sh"
}

@test "authorized deployment retains both exact release candidates after success" {
  MIXLI_CI_RETAIN_RELEASE_IMAGES=1 run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]
  ! grep -Fxq "image rm --force mixli-api-ci:$SHA" "$COMMAND_LOG"
  ! grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
}

@test "rejects an invalid SHA before running server CI" {
  run run_ci "$CHECKOUT" main
  [ "$status" -eq 64 ]
}

@test "rejects a relative or missing checkout" {
  run run_ci relative/path "$SHA"
  [ "$status" -eq 64 ]

  run run_ci "$TEST_ROOT/missing" "$SHA"
  [ "$status" -eq 64 ]
}

@test "runs the complete production CI stage contract in order" {
  run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "source-integrity
infrastructure-contracts
api-postgres-integration
flutter-workspace
platform-declarations
production-builds" ]
}

@test "covers infrastructure API Flutter and production build checks" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  for required in \
    'git diff --check' \
    'docker compose' \
    'rootless_builder_exec bats "${ROOTLESS_HOST_BATS[@]}"' \
    'docker run --rm --network none --read-only --user 101:101' \
    '--add-host api-blue-1:127.0.0.1' \
    '--add-host api-blue-2:127.0.0.1' \
    '--add-host grafana:127.0.0.1' \
    '--tmpfs /var/run:rw,noexec,nosuid,nodev,mode=1777' \
    'MIXLI_HOST_REPO="$CHECKOUT"' \
    'shellcheck' \
    'systemd-analyze verify' \
    '--recursive-errors=no' \
    'mktemp -d /tmp/mixli-systemd-verify.XXXXXX' \
    '$systemd_verify_root/usr/bin/docker' \
    '--entrypoint promtool' \
    'mktemp -d /tmp/mixli-alertmanager-verify.XXXXXX' \
    'mktemp -d /tmp/mixli-prometheus-verify.XXXXXX' \
    'https://example.invalid/hooks/ci' \
    'DATABASE_URL=' \
    '$API_CI_IMAGE' \
    'npm run typecheck' \
    'npm test' \
    'npm run build' \
    'flutter pub get --offline --enforce-lockfile' \
    '"$FLUTTER_IMAGE" bash -c' \
    'dart format --output=none --set-exit-if-changed .' \
    'flutter analyze' \
    'packages/event_delivery && dart test' \
    'dart test --platform chrome test_web' \
    'packages/local_state' \
    'packages/play_flutter' \
    'packages/platform_flutter' \
    'flutter build web --release --pwa-strategy=none' \
    'flutter build apk --release' \
    'apps/api/Dockerfile'; do
    grep -Fq -- "$required" "$script"
  done
}

@test "database integration reuses the image dependency layer" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  integration="$(sed -n '/^api_postgres_integration()/,/^}/p' "$script")"
  [[ "$integration" == *'"$API_TEST_IMAGE"'* ]]
  [[ "$integration" != *'npm ci'* ]]
  grep -Fq 'FROM build AS ci' "$REPO_ROOT/apps/api/Dockerfile"
}

@test "deployment invokes the root-owned server CI helper" {
  grep -Fq '/opt/mixli/bin/server-ci.sh' \
    "$REPO_ROOT/ops/production/bin/deployment.sh"
}

@test "CI validators use the same pinned monitoring images as production" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'prom/prometheus:v3.5.5' "$script"
  grep -Fq 'prom/alertmanager:v0.32.1' "$script"
}

@test "deployment fetches through the build-only repository and pins runtime compose" {
  script="$REPO_ROOT/ops/production/bin/deployment.sh"
  grep -Fq 'MIXLI_REPO:-/srv/mixli/repository' "$script"
  grep -Fq 'runtime/compose.yaml' "$script"
  grep -Fq '$BUILDS/$SHA/ops/production/compose.yaml' "$script"
}

@test "Git trusts only the exact build checkout owned by the locked builder" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  checkout_git="$(sed -n '/^checkout_git()/,/^}/p' "$script")"
  [[ "$checkout_git" == *'runuser -u "$BUILDER_USER" -- git -c safe.directory="$CHECKOUT" -C "$CHECKOUT"'* ]]
  ! grep -Fq 'safe.directory=*' "$script"
}

@test "exact CI checkout is cleaned including ignored and untracked inputs" {
  integrity="$(sed -n '/^source_integrity()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$integrity" == *'checkout_git clean -ffdqx'* ]]
  [[ "$integrity" == *'checkout_git reset --hard "$SHA"'* ]]
}

@test "checkout Bats avoid the production Docker and sudo boundaries" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'ROOTLESS_HOST_BATS=(' "$script"
  grep -Fq 'ROOTLESS_CONTAINER_BATS=(' "$script"
  grep -Fq 'rootless_builder_exec bats "${ROOTLESS_HOST_BATS[@]}"' "$script"
  ! grep -Fq 'builder_exec bats ops/production/tests' "$script"
  suites="$(sed -n '/^readonly ROOTLESS_HOST_BATS=(/,/^)/p; /^readonly ROOTLESS_CONTAINER_BATS=(/,/^)/p' "$script")"
  for required_test in api_image.bats backup_scripts.bats ci_request.bats \
    compose_config.bats deploy_dispatch.bats deployment.bats flutter_image.bats \
    github_workflow.bats hardening_contracts.bats monitoring_config.bats \
    nginx_config.bats postgres_backup.bats postgres_entrypoint.bats \
    provisioning.bats server_ci.bats verify_script.bats; do
    grep -Fq "ops/production/tests/$required_test" <<<"$suites"
  done
}

@test "server CI provisions and deterministically cleans a private rootless daemon" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  provision="$REPO_ROOT/ops/production/bin/provision-host.sh"
  for package in docker-ce-rootless-extras uidmap slirp4netns; do
    grep -Fq "$package" "$provision"
  done
  grep -Fq 'DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=true' "$script"
  grep -Fq 'dockerd-rootless.sh' "$script"
  grep -Fq -- '--exec-opt native.cgroupdriver=cgroupfs' "$script"
  grep -Fq 'DOCKER_HOST="unix://$rootless_runtime/docker.sock"' "$script"
  grep -Fq 'rootless_docker system prune --all --force --volumes' "$script"
  grep -Fq 'rm -rf -- "$rootless_root" "$rootless_runtime"' "$script"
  ! grep -Eq 'DOCKER_HOST=.*(/var/run/docker.sock|/run/docker.sock)' "$script"
}

@test "rootless daemon receives exact candidate images independently of promotion" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'docker save --output "$rootless_archive"' "$script"
  grep -Fq 'rootless_docker load --input "$rootless_archive"' "$script"
  grep -Fq 'rootful_id="$(docker image inspect --format' "$script"
  grep -Fq 'rootless_id="$(rootless_docker image inspect --format' "$script"
  grep -Fq '[[ "$rootful_id" == "$rootless_id" ]]' "$script"
  ! grep -Fq 'rootless_docker build --target ci' "$script"
  grep -Fq 'MIXLI_API_IMAGE="$API_CI_IMAGE"' "$script"
  grep -Fq 'MIXLI_POSTGRES_IMAGE="$POSTGRES_CI_IMAGE"' "$script"
}

@test "ordinary CI builds only an exact-SHA PostgreSQL CI tag and removes it" {
  run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]

  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
  ! grep -Fq 'mixli-postgres:18.3' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'POSTGRES_CI_IMAGE="mixli-postgres-ci:$SHA"' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq -- '-t "$POSTGRES_CI_IMAGE"' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
}

@test "failed CI removes its exact-SHA PostgreSQL CI tag even when retention was requested" {
  MIXLI_CI_TEST_FAIL_STAGE=infrastructure-contracts \
    MIXLI_CI_RETAIN_POSTGRES_IMAGE=1 \
    MIXLI_TEST_DOCKER_RM_FAIL_REF="mixli-postgres-ci:$SHA" \
    run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to remove exact CI image tag mixli-postgres-ci:$SHA."* ]]
  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
}

@test "authorized deployment retention applies only after every CI stage passes" {
  MIXLI_CI_RETAIN_POSTGRES_IMAGE=1 run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]
  ! grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"

  grep -Fq 'MIXLI_CI_RETAIN_RELEASE_IMAGES=1' \
    "$REPO_ROOT/ops/production/bin/deployment.sh"
}

@test "ordinary successful CI fails when its exact PostgreSQL CI tag cannot be removed" {
  MIXLI_TEST_DOCKER_RM_FAIL_REF="mixli-postgres-ci:$SHA" \
    run run_ci "$CHECKOUT" "$SHA"

  [ "$status" -eq 42 ]
  [[ "$output" == *"Failed to remove exact CI image tag mixli-postgres-ci:$SHA."* ]]
  grep -Fxq "image rm --force mixli-postgres-ci:$SHA" "$COMMAND_LOG"
}

@test "accepts only release or review engine modes" {
  MIXLI_CI_TEST_ENGINE_MODE=invalid run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 64 ]

  MIXLI_CI_TEST_ENGINE_MODE=review run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 0 ]
}

@test "review mode rejects release image retention" {
  MIXLI_CI_TEST_ENGINE_MODE=review MIXLI_CI_RETAIN_RELEASE_IMAGES=1 \
    run run_ci "$CHECKOUT" "$SHA"
  [ "$status" -eq 64 ]
}

@test "checkout-controlled host Bats run from the exact checkout directory" {
  infrastructure="$(sed -n '/^infrastructure_contracts()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$infrastructure" == *'(
    cd "$CHECKOUT"
    rootless_builder_exec bats "${ROOTLESS_HOST_BATS[@]}"
  )'* ]]
}

@test "review mode retains every release validation stage" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'MIXLI_CI_ENGINE_MODE' "$script"
  grep -Fq 'review' "$script"
  for stage in source-integrity infrastructure-contracts \
    api-postgres-integration flutter-workspace platform-declarations \
    production-builds; do
    grep -Fq "run_stage $stage" "$script"
  done
}

@test "review web artifacts map back to the isolated host owner" {
  workspace="$(sed -n '/^flutter_workspace()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$workspace" == *'[[ "$ENGINE_MODE" != review ]] || copy_owner=0:0'* ]]
  [[ "$workspace" == *'chown -R $copy_owner /destination'* ]]
}

@test "review Docker CLI state stays in the private unit filesystem" {
  prepare="$(sed -n '/^prepare_ci_engine()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$prepare" == *'mktemp -d /tmp/mixli-docker-config.XXXXXX'* ]]
  [[ "$prepare" == *'printf '\''{}\n'\'' >"$docker_config/config.json"'* ]]
  [[ "$prepare" == *'chmod 0600 "$docker_config/config.json"'* ]]
  [[ "$prepare" == *'export DOCKER_CONFIG="$docker_config"'* ]]
  grep -Fq 'rm -rf -- "$docker_config"' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh"
}

@test "locked builder Docker CLI state is separate from root orchestration state" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  rootless_exec="$(sed -n '/^rootless_builder_exec()/,/^}/p' "$script")"
  start="$(sed -n '/^start_rootless_docker()/,/^}/p' "$script")"

  [[ "$rootless_exec" == *'DOCKER_CONFIG="$rootless_home/.docker"'* ]]
  [[ "$start" == *'"$rootless_home/.docker"'* ]]
  [[ "$start" == *'printf '\''{}\n'\'' | builder_exec tee "$rootless_home/.docker/config.json"'* ]]
  [[ "$start" == *'builder_exec chmod 0600 "$rootless_home/.docker/config.json"'* ]]
}

@test "API tests serialize the shared migration database" {
  grep -Fq \
    '"test": "node --import tsx --test --test-concurrency=1 test/**/*.test.ts"' \
    "$REPO_ROOT/apps/api/package.json"
}

@test "Flutter browser tests receive bounded shared memory" {
  workspace="$(sed -n '/^flutter_workspace()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$workspace" == *'docker run --rm --shm-size=1g'* ]]
}
