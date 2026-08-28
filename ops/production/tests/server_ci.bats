#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  TEST_ROOT="$(mktemp -d)"
  CHECKOUT="$TEST_ROOT/checkout"
  SHA="b5098ec72c804b6df97a7017681ea17b9843d73c"
  mkdir -p "$CHECKOUT"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

run_ci() {
  MIXLI_CI_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/server-ci.sh" "$@"
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
    'bats ops/production/tests' \
    'MIXLI_HOST_REPO="$CHECKOUT"' \
    'shellcheck' \
    'systemd-analyze verify' \
    '--recursive-errors=no' \
    'mktemp -d /tmp/mixli-systemd-verify.XXXXXX' \
    '--entrypoint promtool' \
    'mktemp -d /tmp/mixli-alertmanager-verify.XXXXXX' \
    'https://example.invalid/hooks/ci' \
    'DATABASE_URL=' \
    '$CHECKOUT:/source:ro' \
    'cp -a /source/apps/api/. apps/api/' \
    'npm ci --ignore-scripts' \
    'npm run typecheck' \
    'npm test' \
    'npm run build' \
    'flutter pub get --enforce-lockfile' \
    'dart format --output=none --set-exit-if-changed .' \
    'flutter analyze' \
    'packages/local_state' \
    'packages/play_flutter' \
    'packages/platform_flutter' \
    'flutter build web --release --pwa-strategy=none' \
    'apps/api/Dockerfile'; do
    grep -Fq -- "$required" "$script"
  done
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

@test "deployment defaults to the build-only repository under the service root" {
  script="$REPO_ROOT/ops/production/bin/deployment.sh"
  grep -Fq 'MIXLI_REPO:-/srv/mixli/repository' "$script"
  grep -Fq 'MIXLI_COMPOSE_FILE:-/srv/mixli/repository/ops/production/compose.yaml' "$script"
}

@test "Git trusts only the exact build checkout owned by the locked builder" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'git -c safe.directory="$CHECKOUT" -C "$CHECKOUT"' "$script"
  ! grep -Fq 'safe.directory=*' "$script"
}
