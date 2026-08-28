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
  grep -Fq 'exec "$CI_RUNNER" "$CHECKOUT" "$SHA"' "$script"
}
