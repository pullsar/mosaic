#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PR="${1-}"
readonly SHA="${2-}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly checkout="$ROOT/review-builds/review-$PR-$SHA"
readonly state="$ROOT/state/reviews/$PR"
conclusion=failure
cleanup_status=0

# shellcheck disable=SC2317 # Invoked indirectly by the EXIT cleanup trap.
trusted_git() { runuser -u mixli-build -- git "$@"; }

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
  if [[ -e "$checkout" || -L "$checkout" ]]; then
    if [[ ! -L "$checkout" && "$(readlink -f "$checkout")" == "$checkout" &&
      "$checkout" == "$ROOT"/review-builds/review-"$PR"-"$SHA" ]]; then
      rm -rf -- "$checkout" || cleanup_status=$?
    else
      cleanup_status=64
    fi
  fi
  if [[ -f "$state/latest-sha" && "$(<"$state/latest-sha")" == "$SHA" ]]; then
    trusted_git -C "$REPO" update-ref -d "refs/mixli/reviews/$PR" || cleanup_status=$?
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
  install -d -o root -g root -m 0711 "$ROOT/review-builds"
  git -c safe.directory="$REPO" clone --no-local --no-hardlinks --no-checkout \
    "$REPO" "$checkout"
  git -C "$checkout" checkout --detach "$SHA"
  git -C "$checkout" remote remove origin
  chown -R mixli-review-build:mixli-review-build "$checkout"
  set +e
  timeout --signal=TERM --kill-after=30s 44m \
    env MIXLI_CI_ENGINE_MODE=review MIXLI_CI_BUILDER_USER=mixli-review-build \
      MIXLI_ROOTLESS_STORAGE_PARENT="$ROOT/review-builds" MIXLI_CI_RETAIN_RELEASE_IMAGES=0 \
      /opt/mixli/bin/server-ci.sh "$checkout" "$SHA"
  result=$?
  set -e
  exit "$result"
}

main
