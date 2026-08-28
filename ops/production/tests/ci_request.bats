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

@test "fetches branches and pull requests before requiring remote reachability" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq '+refs/heads/*:refs/remotes/origin/*' "$script"
  grep -Fq '+refs/pull/*/head:refs/remotes/origin/pull/*' "$script"
  grep -Fq 'merge-base --is-ancestor' "$script"
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

@test "deployment requests enqueue the synchronous deployer" {
  request="$REPO_ROOT/ops/production/bin/deployment-request.sh"
  run env MIXLI_DEPLOY_REQUEST_TEST_MODE=1 "$request" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "queued:mixli-deploy-${SHA:0:12}" ]
  grep -Fq '/opt/mixli/bin/deployment.sh "$SHA"' "$request"
}
