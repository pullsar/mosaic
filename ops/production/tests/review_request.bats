#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
  REQUEST="$REPO_ROOT/ops/production/bin/review-request.sh"
}

@test "review forced command accepts only decimal PR and exact lowercase SHA" {
  run env SSH_ORIGINAL_COMMAND="review $PR $SHA" MIXLI_REVIEW_DISPATCH_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/review-dispatch"
  [ "$status" -eq 0 ]
  [ "$output" = "review:$PR:$SHA" ]

  for command in "review x $SHA" "review -1 $SHA" "review $PR main" \
    "review $PR ${SHA};id" "deploy $SHA" ""; do
    run env SSH_ORIGINAL_COMMAND="$command" MIXLI_REVIEW_DISPATCH_TEST_MODE=1 \
      "$REPO_ROOT/ops/production/bin/review-dispatch"
    [ "$status" -eq 64 ]
  done
}

@test "request test mode validates inputs without fetching" {
  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" "$PR" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "review:$PR:$SHA" ]

  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" 0 "$SHA"
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" "$PR" MAIN
  [ "$status" -eq 64 ]
}

@test "request fetches only the numbered PR ref and verifies exact equality" {
  grep -Fq 'fetch --force --no-tags origin "+refs/pull/$PR/head:$REVIEW_REF"' "$REQUEST"
  grep -Fq 'actual="$(builder_git -C "$REPO" rev-parse "$REVIEW_REF^{commit}")"' "$REQUEST"
  grep -Fq '[[ "$actual" == "$SHA" ]]' "$REQUEST"
  ! grep -Fq '+refs/heads/*' "$REQUEST"
  ! grep -Fq '+refs/pull/*' "$REQUEST"
}

@test "request supersedes an older PR unit and queues bounded review work" {
  grep -Fq 'flock -w 30 9' "$REQUEST"
  grep -Fq 'systemctl is-active --quiet "$previous_unit"' "$REQUEST"
  grep -Fq 'systemctl stop "$previous_unit"' "$REQUEST"
  ! grep -Fq 'systemctl stop "$previous_unit" || true' "$REQUEST"
  grep -Fq 'mixli-review-${PR}-${SHA:0:12}' "$REQUEST"
  grep -Fq -- '--property=RuntimeMaxSec=45min' "$REQUEST"
  grep -Fq -- '--property=TimeoutStopSec=2min' "$REQUEST"
  grep -Fq -- '--property=CPUQuota=600%' "$REQUEST"
  grep -Fq -- '--property=MemoryHigh=12G' "$REQUEST"
  grep -Fq -- '--property=MemoryMax=16G' "$REQUEST"
  grep -Fq -- '--property=TasksMax=4096' "$REQUEST"
  grep -Fq -- '--property=IOWeight=100' "$REQUEST"
  grep -Fq -- '--property=Nice=10' "$REQUEST"
  grep -Fq -- '--property=PrivateTmp=yes' "$REQUEST"
  grep -Fq -- '--property=ProtectHome=yes' "$REQUEST"
  grep -Fq -- '--property=ProtectSystem=strict' "$REQUEST"
  grep -Fq -- '--property="ReadWritePaths=$REVIEW_ROOT $ROOT/state/reviews $ROOT/log $REPO"' "$REQUEST"
  grep -Fq '/opt/mixli/bin/review-ci.sh "$PR" "$SHA"' "$REQUEST"
}

@test "duplicate active PR and SHA requests are idempotent" {
  grep -Fq '"$previous_unit" == "$UNIT"' "$REQUEST"
  grep -Fq '"$previous_sha" == "$SHA"' "$REQUEST"
  grep -Fq 'systemctl is-active --quiet "$UNIT"' "$REQUEST"
  grep -Fq 'printf '\''queued:%s\n'\'' "$UNIT"' "$REQUEST"
  grep -Fq 'return 0' "$REQUEST"
}
