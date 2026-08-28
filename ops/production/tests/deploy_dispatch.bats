#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
}

@test "accepts deploy followed by a 40-character lowercase SHA" {
  run env \
    SSH_ORIGINAL_COMMAND="deploy b5098ec72c804b6df97a7017681ea17b9843d73c" \
    MIXLI_DEPLOY_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/deploy-dispatch"

  [ "$status" -eq 0 ]
  [ "$output" = "b5098ec72c804b6df97a7017681ea17b9843d73c" ]
}

@test "rejects shell metacharacters" {
  run env \
    SSH_ORIGINAL_COMMAND="deploy b5098ec72c804b6df97a7017681ea17b9843d73c;id" \
    MIXLI_DEPLOY_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/deploy-dispatch"

  [ "$status" -eq 64 ]
}

@test "rejects uppercase SHA characters" {
  run env \
    SSH_ORIGINAL_COMMAND="deploy B5098ec72c804b6df97a7017681ea17b9843d73c" \
    MIXLI_DEPLOY_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/deploy-dispatch"

  [ "$status" -eq 64 ]
}

@test "rejects an interactive shell" {
  run env \
    SSH_ORIGINAL_COMMAND="" \
    MIXLI_DEPLOY_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/deploy-dispatch"

  [ "$status" -eq 64 ]
}
