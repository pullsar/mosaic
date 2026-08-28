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
    'shellcheck' \
    'systemd-analyze verify' \
    'DATABASE_URL=' \
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
    grep -Fq "$required" "$script"
  done
}

@test "deployment invokes the root-owned server CI helper" {
  grep -Fq '/opt/mixli/bin/server-ci.sh' \
    "$REPO_ROOT/ops/production/bin/deployment.sh"
}
