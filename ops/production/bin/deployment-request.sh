#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SHA="${1-}"
readonly TEST_MODE="${MIXLI_DEPLOY_REQUEST_TEST_MODE:-0}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly RUNNERS="$ROOT/state/deploy-runners"
readonly RUNNER_ROOT="$RUNNERS/$SHA"
readonly DEPLOY_RUNNER="$RUNNER_ROOT/deployment.sh"
readonly CI_RUNNER="$RUNNER_ROOT/server-ci.sh"
readonly VERIFY_RUNNER="$RUNNER_ROOT/verify-production.sh"

if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'deployment-request.sh requires an exact 40-character lowercase commit SHA.' >&2
  exit 64
fi

readonly unit="mixli-deploy-${SHA:0:12}"
if [[ "$TEST_MODE" == '1' ]]; then
  printf 'queued:%s\n' "$unit"
  exit 0
fi

builder_git() {
  runuser -u mixli-build -- git "$@"
}

verify_ancestry() {
  builder_git -C "$REPO" fetch --prune origin main
  builder_git -C "$REPO" cat-file -e "$SHA^{commit}" || exit 65
  builder_git -C "$REPO" merge-base --is-ancestor "$SHA" origin/main || exit 65
}

verify_staged_file() {
  local source="$1" destination="$2"
  builder_git -C "$REPO" show "$SHA:$source" | cmp -s - "$destination"
}

stage_runner() {
  local temporary="$RUNNERS/.$SHA.$$.tmp" source destination
  local -a files=(
    ops/production/bin/deployment.sh
    ops/production/bin/server-ci.sh
    ops/production/bin/verify-production.sh
  )

  install -d -o root -g root -m 0750 "$RUNNERS"
  if [[ -d "$RUNNER_ROOT" ]]; then
    verify_staged_file ops/production/bin/deployment.sh "$DEPLOY_RUNNER"
    verify_staged_file ops/production/bin/server-ci.sh "$CI_RUNNER"
    verify_staged_file ops/production/bin/verify-production.sh "$VERIFY_RUNNER"
    return 0
  fi

  install -d -o root -g root -m 0750 "$temporary"
  for source in "${files[@]}"; do
    destination="$temporary/$(basename "$source")"
    builder_git -C "$REPO" show "$SHA:$source" >"$destination"
    chmod 0755 "$destination"
  done
  mv -T "$temporary" "$RUNNER_ROOT"
}

install_current_verifier() {
  local temporary="/opt/mixli/bin/.verify-production.sh.$$.tmp"
  install -o root -g root -m 0755 "$VERIFY_RUNNER" "$temporary"
  mv -fT "$temporary" /opt/mixli/bin/verify-production.sh
}

verify_ancestry
stage_runner
install_current_verifier
systemctl stop 'mixli-review-*'

systemd-run --quiet --no-block --collect --unit="$unit" \
  --property=Type=exec --property=TimeoutStartSec=2h \
  --setenv=MIXLI_CI_RUNNER="$CI_RUNNER" \
  "$DEPLOY_RUNNER" "$SHA"
printf 'queued:%s\n' "$unit"
