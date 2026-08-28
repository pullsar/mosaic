#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SHA="${1-}"
readonly TEST_MODE="${MIXLI_DEPLOY_REQUEST_TEST_MODE:-0}"

if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'deployment-request.sh requires an exact 40-character lowercase commit SHA.' >&2
  exit 64
fi

readonly unit="mixli-deploy-${SHA:0:12}"
if [[ "$TEST_MODE" == '1' ]]; then
  printf 'queued:%s\n' "$unit"
  exit 0
fi

systemd-run --quiet --no-block --collect --unit="$unit" \
  --property=Type=exec --property=TimeoutStartSec=2h \
  /opt/mixli/bin/deployment.sh "$SHA"
printf 'queued:%s\n' "$unit"
