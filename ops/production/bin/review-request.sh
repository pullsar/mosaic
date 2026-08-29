#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PR="${1-}"
readonly SHA="${2-}"
readonly TEST_MODE="${MIXLI_REVIEW_REQUEST_TEST_MODE:-0}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly REVIEW_REF="refs/mixli/reviews/$PR"
readonly REVIEW_STATE="$ROOT/state/reviews/$PR"
readonly REQUEST_LOCK="${MIXLI_REVIEW_REQUEST_LOCK:-/run/lock/mixli-review-request.lock}"
readonly UNIT="mixli-review-${PR}-${SHA:0:12}"

builder_git() { runuser -u mixli-build -- git "$@"; }

validate_inputs() {
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || exit 64
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 64
}

verify_pr_ref() {
  local actual
  builder_git -C "$REPO" fetch --force --no-tags origin \
    "+refs/pull/$PR/head:$REVIEW_REF"
  actual="$(builder_git -C "$REPO" rev-parse "$REVIEW_REF^{commit}")"
  [[ "$actual" == "$SHA" ]] || exit 65
}

queue_review() {
  local previous_unit=''
  install -d -o root -g root -m 0750 "$ROOT/state/reviews" "$REVIEW_STATE"
  if [[ -f "$REVIEW_STATE/unit" ]]; then
    previous_unit="$(<"$REVIEW_STATE/unit")"
  fi
  printf '%s\n' "$SHA" >"$REVIEW_STATE/latest-sha"
  printf '%s\n' "$UNIT" >"$REVIEW_STATE/unit"
  chmod 0640 "$REVIEW_STATE/latest-sha" "$REVIEW_STATE/unit"
  if [[ -n "$previous_unit" && "$previous_unit" != "$UNIT" ]] && \
    systemctl is-active --quiet "$previous_unit"; then
    systemctl stop "$previous_unit"
  fi
  /opt/mixli/bin/review-status.sh create "$PR" "$SHA" queued
  if ! systemd-run --quiet --no-block --collect --unit="$UNIT" \
    --property=Type=exec \
    --property=RuntimeMaxSec=45min \
    --property=TimeoutStopSec=2min \
    --property=CPUQuota=600% \
    --property=MemoryMax=12G \
    --property=IOWeight=100 \
    --property=Nice=10 \
    --property=KillMode=control-group \
    /opt/mixli/bin/review-ci.sh "$PR" "$SHA"; then
    /opt/mixli/bin/review-status.sh update "$PR" "$SHA" failure || true
    return 75
  fi
  printf 'queued:%s\n' "$UNIT"
}

main() {
  validate_inputs
  if [[ "$TEST_MODE" == '1' ]]; then
    printf 'review:%s:%s\n' "$PR" "$SHA"
    return 0
  fi
  install -d -m 0750 "$(dirname "$REQUEST_LOCK")"
  exec 9>"$REQUEST_LOCK"
  flock -w 30 9 || exit 75
  verify_pr_ref
  queue_review
}

main
