#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SHA="${1-}"
readonly TEST_MODE="${MIXLI_CI_REQUEST_TEST_MODE:-0}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly CI_RUNNER="${MIXLI_CI_RUNNER:-/opt/mixli/bin/server-ci.sh}"
readonly LOCK_FILE="${MIXLI_CI_LOCK_FILE:-/run/lock/mixli-ci.lock}"
readonly CHECKOUT="$ROOT/builds/$SHA"

builder_git() {
  runuser -u mixli-build -- git "$@"
}

validate_sha() {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || {
    printf '%s\n' 'ci-request.sh requires an exact 40-character lowercase commit SHA.' >&2
    exit 64
  }
}

fetch_and_verify() {
  local ref allowed=0
  builder_git -C "$REPO" fetch --prune origin \
    '+refs/heads/*:refs/remotes/origin/*' \
    '+refs/pull/*/head:refs/remotes/origin/pull/*'
  builder_git -C "$REPO" cat-file -e "$SHA^{commit}" || exit 65

  while IFS= read -r ref; do
    if builder_git -C "$REPO" merge-base --is-ancestor "$SHA" "$ref"; then
      allowed=1
      break
    fi
  done < <(builder_git -C "$REPO" for-each-ref \
    --format='%(refname)' refs/remotes/origin)
  [[ "$allowed" == '1' ]] || exit 65
}

prepare_checkout() {
  local actual
  if [[ -e "$CHECKOUT" ]]; then
    [[ -e "$CHECKOUT/.git" ]] || exit 66
    actual="$(builder_git -C "$CHECKOUT" rev-parse HEAD)"
    [[ "$actual" == "$SHA" ]] || exit 66
    return 0
  fi
  install -d -o mixli-build -g mixli-build -m 0750 "$ROOT/builds"
  builder_git -C "$REPO" worktree add --detach "$CHECKOUT" "$SHA"
}

main() {
  validate_sha
  if [[ "$TEST_MODE" == '1' ]]; then
    printf '%s\n' "$SHA"
    return 0
  fi
  install -d -m 0750 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 75
  fetch_and_verify
  prepare_checkout
  exec "$CI_RUNNER" "$CHECKOUT" "$SHA"
}

main
