#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  REVIEW="$REPO_ROOT/ops/production/bin/review-ci.sh"
  SERVER="$REPO_ROOT/ops/production/bin/server-ci.sh"
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
}

@test "review wrapper selects only review engine mode" {
  grep -Fq 'MIXLI_CI_ENGINE_MODE=review' "$REVIEW"
  grep -Fq 'MIXLI_CI_BUILDER_USER=mixli-review-build' "$REVIEW"
  grep -Fq 'MIXLI_ROOTLESS_RUNTIME_PARENT="$REVIEW_ROOT/runtime"' "$REVIEW"
  grep -Fq '/opt/mixli/bin/server-ci.sh "$checkout" "$SHA"' "$REVIEW"
  ! grep -Eq 'deployment|promote|MIXLI_CI_RETAIN_RELEASE_IMAGES=1' "$REVIEW"
}

@test "review mode makes rootless Docker authoritative before candidate builds" {
  prepare="$(sed -n '/^prepare_ci_engine()/,/^}/p' "$SERVER")"
  [[ "$prepare" == *'start_rootless_docker'* ]]
  [[ "$prepare" == *'export DOCKER_HOST="unix://$rootless_runtime/docker.sock"'* ]]
  [[ "$prepare" == *'docker info'* ]]
  [[ "$prepare" == *'name=rootless'* ]]
  [[ "$prepare" != *'docker save'* ]]
  [[ "$prepare" != *'docker load'* ]]
}

@test "release mode retains exact rootful to rootless image identity verification" {
  grep -Fq 'load_rootless_candidate_images' "$SERVER"
  grep -Fq '[[ "$rootful_id" == "$rootless_id" ]]' "$SERVER"
  grep -Fq 'MIXLI_CI_ENGINE_MODE:-release' "$SERVER"
}

@test "review cleanup removes daemon checkout and fetched ref at their owning boundaries" {
  cleanup="$(sed -n '/^cleanup()/,/^}/p' "$SERVER")"
  [[ "$cleanup" == *'stop_rootless_docker'* ]]
  grep -Fq 'rm -rf -- "$checkout"' "$REVIEW"
  grep -Fq '"$(<"$state/latest-sha")" == "$SHA"' "$REVIEW"
  grep -Fq 'update-ref -d "refs/mixli/reviews/$PR"' "$REVIEW"
  grep -Fq 'cleanup failure' "$REVIEW"
  ! grep -Fq 'stop_rootless_docker' "$REVIEW"
}

@test "review source runs from an isolated clone outside the trusted mirror owner" {
  grep -Fq 'clone --no-local --no-hardlinks --no-checkout' "$REVIEW"
  grep -Fq 'install -d -o mixli-build -g mixli-build -m 0700 "$checkout"' "$REVIEW"
  grep -Fq 'fetch --no-tags origin "$SHA"' "$REVIEW"
  grep -Fq 'rev-parse FETCH_HEAD' "$REVIEW"
  grep -Fq 'chown -R mixli-review-build:mixli-review-build "$checkout"' "$REVIEW"
  grep -Fq 'remote remove origin' "$REVIEW"
  ! grep -Fq 'worktree add' "$REVIEW"
  grep -Fq 'builds/review-$PR-$SHA' "$REVIEW"
  grep -Fq 'MIXLI_REVIEW_ROOT:-/srv/mixli-review' "$REVIEW"
}

@test "review lifecycle distinguishes success failure cancellation and timeout" {
  for state in in_progress success failure cancelled timed_out; do
    grep -Fq 'review-status.sh update' "$REVIEW"
    grep -Fq "$state" "$REVIEW"
  done
  grep -Fq 'trap on_term TERM INT' "$REVIEW"
  grep -Fq 'timeout --signal=TERM --kill-after=30s 44m' "$REVIEW"
  grep -Fq 'latest-sha' "$REVIEW"
}
