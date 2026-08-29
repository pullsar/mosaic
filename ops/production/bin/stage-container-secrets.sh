#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_DIR="${MIXLI_SECRET_SOURCE_DIR:-/etc/mixli/secrets}"
readonly STAGE_DIR="${MIXLI_CONTAINER_SECRET_DIR:-/run/mixli/container-secrets}"

[[ "$EUID" -eq 0 ]]
install -d -o root -g root -m 0755 "$STAGE_DIR"

alert_tmp="$STAGE_DIR/.alertmanager-webhook-url.$$"
grafana_tmp="$STAGE_DIR/.grafana-admin-password.$$"
trap 'rm -f -- "$alert_tmp" "$grafana_tmp"' EXIT

install -o 65534 -g 65534 -m 0400 \
  "$SOURCE_DIR/alertmanager-webhook-url" "$alert_tmp"
install -o 472 -g 472 -m 0400 \
  "$SOURCE_DIR/grafana-admin-password" "$grafana_tmp"
mv -fT "$alert_tmp" "$STAGE_DIR/alertmanager-webhook-url"
mv -fT "$grafana_tmp" "$STAGE_DIR/grafana-admin-password"
