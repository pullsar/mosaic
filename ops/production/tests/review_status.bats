#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  STATUS="$REPO_ROOT/ops/production/bin/review-status.sh"
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
}

@test "status helper accepts only known lifecycle transitions" {
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" create "$PR" "$SHA" queued
  [ "$status" -eq 0 ]
  jq -e '.state == "queued"' <<<"$output" >/dev/null

  for state in in_progress success failure cancelled timed_out; do
    run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" "$state"
    [ "$status" -eq 0 ]
    jq -e --arg state "$state" '.state == $state' <<<"$output" >/dev/null
  done
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" create "$PR" "$SHA" success
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" queued
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" neutral
  [ "$status" -eq 64 ]
}

@test "completed payload maps state to an explicit conclusion" {
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" timed_out
  [ "$status" -eq 0 ]
  jq -e '.status == "completed" and .conclusion == "timed_out"' <<<"$output" >/dev/null

  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" failure
  jq -e '.status == "completed" and .conclusion == "failure"' <<<"$output" >/dev/null
}

@test "GitHub App credentials remain root-only and outside checkout" {
  grep -Fq '/etc/mixli/github/app-id' "$STATUS"
  grep -Fq '/etc/mixli/github/installation-id' "$STATUS"
  grep -Fq '/etc/mixli/github/private-key.pem' "$STATUS"
  ! grep -Fq 'GITHUB_TOKEN' "$STATUS"
  ! grep -Fq 'MIXLI_DEPLOY' "$STATUS"
}

@test "API failures use bounded retries and fail nonzero" {
  grep -Fq 'for attempt in 1 2 3 4 5' "$STATUS"
  grep -Fq 'sleep "$attempt"' "$STATUS"
  [ "$(grep -Fc -- '--connect-timeout 10' "$STATUS")" -eq 2 ]
  [ "$(grep -Fc -- '--max-time 30' "$STATUS")" -eq 2 ]
  grep -Fq 'return 75' "$STATUS"

  local_audit_line="$(grep -n 'audit_event local' "$STATUS" | cut -d: -f1)"
  api_line="$(grep -n 'response="$(api_call POST' "$STATUS" | cut -d: -f1)"
  [ -n "$local_audit_line" ]
  [ -n "$api_line" ]
  [ "$local_audit_line" -lt "$api_line" ]
}
