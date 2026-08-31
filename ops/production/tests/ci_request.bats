#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  SHA="b5098ec72c804b6df97a7017681ea17b9843d73c"
}

@test "rejects anything except an exact lowercase SHA" {
  run env MIXLI_CI_REQUEST_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/ci-request.sh" 'main;id'
  [ "$status" -eq 64 ]
}

@test "accepts an exact SHA without touching the repository in test mode" {
  run env MIXLI_CI_REQUEST_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/ci-request.sh" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "$SHA" ]
}

@test "fetches protected main before requiring main ancestry" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq 'fetch --prune origin main' "$script"
  grep -Fq 'merge-base --is-ancestor "$SHA" origin/main' "$script"
  ! grep -Fq '+refs/heads/*:refs/remotes/origin/*' "$script"
  ! grep -Fq '+refs/pull/*/head:refs/remotes/origin/pull/*' "$script"
}

@test "runs only the root-owned server CI helper against the exact checkout" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq 'if "$CI_RUNNER" "$CHECKOUT" "$SHA"; then' "$script"
}

@test "hosted requests enqueue a transient worker and return immediately" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq 'systemd-run --quiet --no-block --collect' "$script"
  grep -Fq -- '--setenv=MIXLI_CI_REQUEST_WORKER=1' "$script"
  grep -Fq 'ci-passed' "$script"
  grep -Fq 'ci-failed' "$script"
}

@test "server workers serialize with a bounded wait instead of dropping pushes" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq 'flock -w 2400 9' "$script"
  ! grep -Fq 'flock -n 9' "$script"
  grep -Fq 'log_result ci-failed' "$script"
}

@test "deployment requests enqueue the exact SHA versioned deployer" {
  request="$REPO_ROOT/ops/production/bin/deployment-request.sh"
  run env MIXLI_DEPLOY_REQUEST_TEST_MODE=1 "$request" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "queued:mixli-deploy-${SHA:0:12}" ]
  grep -Fq 'fetch --prune origin main' "$request"
  grep -Fq 'merge-base --is-ancestor "$SHA" origin/main' "$request"
  grep -Fq 'RUNNER_ROOT="$RUNNERS/$SHA"' "$request"
  grep -Fq 'DEPLOY_RUNNER="$RUNNER_ROOT/deployment.sh"' "$request"
  grep -Fq 'CI_RUNNER="$RUNNER_ROOT/server-ci.sh"' "$request"
  grep -Fq 'show "$SHA:$source"' "$request"
  grep -Fq -- '--setenv=MIXLI_CI_RUNNER="$CI_RUNNER"' "$request"
  grep -Fq '"$DEPLOY_RUNNER" "$SHA"' "$request"
  ! grep -Fq '/opt/mixli/bin/deployment.sh "$SHA"' "$request"
}

@test "production deployment synchronously preempts review units" {
  request="$REPO_ROOT/ops/production/bin/deployment-request.sh"
  stop_line="$(grep -Fn "systemctl stop 'mixli-review-*'" "$request" | cut -d: -f1)"
  queue_line="$(grep -n 'systemd-run --quiet' "$request" | cut -d: -f1)"
  [ -n "$stop_line" ]
  [ -n "$queue_line" ]
  [ "$stop_line" -lt "$queue_line" ]
  ! grep -Fq "systemctl stop 'mixli-review-*' || true" "$request"
}
