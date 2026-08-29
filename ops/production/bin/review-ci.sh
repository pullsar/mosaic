#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PR="${1-}"
readonly SHA="${2-}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly checkout="$ROOT/builds/review-$PR-$SHA"
readonly state="$ROOT/state/reviews/$PR"
conclusion=failure
cleanup_status=0

builder_git() { runuser -u mixli-build -- git "$@"; }

# shellcheck disable=SC2317 # Invoked indirectly by the TERM/INT trap.
on_term() {
  conclusion=cancelled
  exit 143
}

# shellcheck disable=SC2317 # Invoked indirectly by the EXIT trap.
cleanup() {
  local original="$1"
  trap - EXIT TERM INT
  set +e
  if [[ -e "$checkout/.git" ]]; then
    builder_git -C "$REPO" worktree remove --force "$checkout" || cleanup_status=$?
  fi
  if [[ -f "$state/latest-sha" && "$(<"$state/latest-sha")" == "$SHA" ]]; then
    builder_git -C "$REPO" update-ref -d "refs/mixli/reviews/$PR" || cleanup_status=$?
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    printf '%s\n' 'review cleanup failure' >&2
    conclusion=failure
  fi
  if [[ -f "$state/latest-sha" && "$(<"$state/latest-sha")" != "$SHA" ]]; then
    conclusion=cancelled
  elif [[ "$original" -eq 124 || "$original" -eq 143 ]]; then
    conclusion=$([[ "$original" -eq 124 ]] && printf timed_out || printf cancelled)
  elif [[ "$original" -eq 0 && "$cleanup_status" -eq 0 ]]; then
    conclusion=success
  fi
  /opt/mixli/bin/review-status.sh update "$PR" "$SHA" "$conclusion" || exit 75
  [[ "$original" -ne 0 ]] && exit "$original"
  exit "$cleanup_status"
}

main() {
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || exit 64
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 64
  trap on_term TERM INT
  trap 'cleanup $?' EXIT
  /opt/mixli/bin/review-status.sh update "$PR" "$SHA" in_progress
  install -d -o mixli-build -g mixli-build -m 0750 "$ROOT/builds"
  builder_git -C "$REPO" worktree add --detach "$checkout" "$SHA"
  set +e
  timeout --signal=TERM --kill-after=30s 44m \
    env MIXLI_CI_ENGINE_MODE=review MIXLI_CI_RETAIN_RELEASE_IMAGES=0 \
      /opt/mixli/bin/server-ci.sh "$checkout" "$SHA"
  result=$?
  set -e
  exit "$result"
}

main
