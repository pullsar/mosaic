#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  TEST_ROOT="$(mktemp -d)"
  SHA="b5098ec72c804b6df97a7017681ea17b9843d73c"
  OLD_SHA="1111111111111111111111111111111111111111"
  PREVIOUS_SHA="2222222222222222222222222222222222222222"
  mkdir -p "$TEST_ROOT/releases/$OLD_SHA/web" "$TEST_ROOT/releases/$PREVIOUS_SHA/web" \
    "$TEST_ROOT/runtime" "$TEST_ROOT/state" "$TEST_ROOT/log" "$TEST_ROOT/locks" "$TEST_ROOT/repo"
  printf 'old-web' >"$TEST_ROOT/releases/$OLD_SHA/web/index.html"
  printf 'previous-web' >"$TEST_ROOT/releases/$PREVIOUS_SHA/web/index.html"
  ln -s "$TEST_ROOT/releases/$OLD_SHA" "$TEST_ROOT/current"
  printf '{"sha":"%s","pool":"blue"}\n' "$OLD_SHA" >"$TEST_ROOT/state/current.json"
  printf '{"sha":"%s","pool":"green"}\n' "$PREVIOUS_SHA" >"$TEST_ROOT/state/previous.json"
  printf 'old-upstream\n' >"$TEST_ROOT/runtime/api-upstream.conf"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

deploy() {
  env \
    MIXLI_DEPLOY_TEST_MODE=1 \
    MIXLI_ROOT="$TEST_ROOT" \
    MIXLI_REPO="$TEST_ROOT/repo" \
    MIXLI_LOCK_FILE="$TEST_ROOT/locks/deploy.lock" \
    MIXLI_TEST_SHA_ALLOWED="${MIXLI_TEST_SHA_ALLOWED:-1}" \
    MIXLI_TEST_FAIL_STAGE="${MIXLI_TEST_FAIL_STAGE:-}" \
    MIXLI_DRAIN_SECONDS=0 \
    "$REPO_ROOT/ops/production/bin/deployment.sh" "$@"
}

@test "rejects anything except an exact lowercase SHA" {
  run deploy 'main; id'
  [ "$status" -eq 64 ]
}

@test "rejects a SHA outside origin main ancestry" {
  MIXLI_TEST_SHA_ALLOWED=0 run deploy "$SHA"
  [ "$status" -eq 65 ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "exclusive lock rejects a concurrent deployment" {
  exec 8>"$TEST_ROOT/locks/deploy.lock"
  flock -n 8
  run deploy "$SHA"
  exec 8>&-
  [ "$status" -eq 75 ]
}

@test "selects the inactive pool and requires five consecutive readiness passes" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  grep -q 'server api-green-1:8080' "$TEST_ROOT/runtime/api-upstream.conf"
  grep -q 'server api-green-2:8080' "$TEST_ROOT/runtime/api-upstream.conf"
  [ "$(grep -c '^ready:green:' "$TEST_ROOT/log/deploy-events.log")" -eq 5 ]
}

@test "build failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=build run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "migration failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=migration run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "readiness failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=readiness run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "Nginx validation failure restores the prior on-disk upstream" {
  MIXLI_TEST_FAIL_STAGE=nginx run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
}

@test "successful deploy atomically switches web and records current and previous releases" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  [ -L "$TEST_ROOT/current" ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$SHA" ]
  grep -q "\"sha\":\"$SHA\"" "$TEST_ROOT/state/current.json"
  grep -q '"pool":"green"' "$TEST_ROOT/state/current.json"
  grep -q "\"sha\":\"$OLD_SHA\"" "$TEST_ROOT/state/previous.json"
  [ -f "$TEST_ROOT/releases/$SHA/release.json" ]
}

@test "public smoke failure rolls back both atomic switches" {
  MIXLI_TEST_FAIL_STAGE=public-smoke run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/runtime/api-upstream.conf")" = 'old-upstream' ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
  grep -q "\"sha\":\"$OLD_SHA\"" "$TEST_ROOT/state/current.json"
}

@test "failed first deployment leaves no latent upstream or web link" {
  rm -f "$TEST_ROOT/current" "$TEST_ROOT/runtime/api-upstream.conf" \
    "$TEST_ROOT/state/current.json" "$TEST_ROOT/state/previous.json"
  MIXLI_TEST_FAIL_STAGE=public-smoke run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/runtime/api-upstream.conf" ]
  [ ! -e "$TEST_ROOT/current" ]
}

@test "retention keeps current and previous while bounding other releases" {
  local n old
  for n in 3 4 5 6 7 8 9; do
    old="$(printf '%040d' "$n")"
    mkdir -p "$TEST_ROOT/releases/$old/web"
    touch -d "2026-08-$((10 + n))" "$TEST_ROOT/releases/$old"
  done

  run deploy "$SHA"
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/releases/$SHA" ]
  [ -d "$TEST_ROOT/releases/$OLD_SHA" ]
  [ "$(find "$TEST_ROOT/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 7 ]
}
