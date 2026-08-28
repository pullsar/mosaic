#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly CHECKOUT="${1-}"
readonly SHA="${2-}"
readonly TEST_MODE="${MIXLI_CI_TEST_MODE:-0}"
readonly SHORT_SHA="${SHA:0:12}"
readonly FLUTTER_IMAGE="${MIXLI_FLUTTER_CI_IMAGE:-mixli-flutter-builder:3.44.7}"
readonly POSTGRES_IMAGE="${MIXLI_POSTGRES_CI_IMAGE:-mixli-postgres:18.3}"
readonly API_IMAGE="mixli-api:$SHA"
readonly API_CI_IMAGE="mixli-api-ci:$SHA"
readonly PROMETHEUS_IMAGE="${MIXLI_PROMETHEUS_CI_IMAGE:-prom/prometheus:v3.5.5}"
readonly ALERTMANAGER_IMAGE="${MIXLI_ALERTMANAGER_CI_IMAGE:-prom/alertmanager:v0.32.1}"

network=''
postgres_container=''
systemd_verify_root=''
alertmanager_verify_root=''
prometheus_verify_root=''

die_usage() {
  printf '%s\n' 'server-ci.sh requires an absolute checkout and exact lowercase commit SHA.' >&2
  exit 64
}

checkout_git() {
  git -c safe.directory="$CHECKOUT" -C "$CHECKOUT" "$@"
}

cleanup() {
  docker image rm "$API_CI_IMAGE" >/dev/null 2>&1 || true
  if [[ -n "$postgres_container" ]]; then
    docker rm -f "$postgres_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$network" ]]; then
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
  if [[ "$systemd_verify_root" == /tmp/mixli-systemd-verify.* && -d "$systemd_verify_root" ]]; then
    rm -rf -- "$systemd_verify_root"
  fi
  if [[ "$alertmanager_verify_root" == /tmp/mixli-alertmanager-verify.* && -d "$alertmanager_verify_root" ]]; then
    rm -rf -- "$alertmanager_verify_root"
  fi
  if [[ "$prometheus_verify_root" == /tmp/mixli-prometheus-verify.* && -d "$prometheus_verify_root" ]]; then
    rm -rf -- "$prometheus_verify_root"
  fi
}

validate_inputs() {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die_usage
  [[ "$CHECKOUT" == /* && "$CHECKOUT" != '/' && -d "$CHECKOUT" ]] || die_usage
  [[ "$(readlink -f "$CHECKOUT")" == "$CHECKOUT" ]] || die_usage

  if [[ "$TEST_MODE" != '1' ]]; then
    [[ -e "$CHECKOUT/.git" ]] || die_usage
    [[ "$(checkout_git rev-parse HEAD)" == "$SHA" ]] || die_usage
  fi
}

run_stage() {
  local name="$1" implementation="$2"
  printf '%s\n' "$name"
  [[ "$TEST_MODE" == '1' ]] || "$implementation"
}

source_integrity() {
  checkout_git diff --check
  [[ -z "$(checkout_git status --porcelain --untracked-files=no)" ]]
}

infrastructure_contracts() {
  docker build --target ci -f "$CHECKOUT/apps/api/Dockerfile" \
    -t "$API_CI_IMAGE" "$CHECKOUT"
  docker build -f "$CHECKOUT/apps/api/Dockerfile" -t "$API_IMAGE" "$CHECKOUT"
  docker build -f "$CHECKOUT/ops/production/flutter/Dockerfile" \
    -t "$FLUTTER_IMAGE" "$CHECKOUT/ops/production/flutter"
  docker build -f "$CHECKOUT/ops/production/postgres/Dockerfile" \
    -t "$POSTGRES_IMAGE" "$CHECKOUT/ops/production/postgres"

  (
    cd "$CHECKOUT"
    docker compose --env-file ops/production/env/production.env.example \
      -f ops/production/compose.yaml config --quiet
    MIXLI_API_IMAGE="$API_IMAGE" \
      MIXLI_FLUTTER_IMAGE="$FLUTTER_IMAGE" \
      MIXLI_POSTGRES_IMAGE="$POSTGRES_IMAGE" \
      MIXLI_HOST_REPO="$CHECKOUT" \
      bats ops/production/tests
  )

  mapfile -d '' shell_files < <(
    find "$CHECKOUT/ops/production/bin" -maxdepth 1 -type f \
      \( -name '*.sh' -o -name 'deploy-dispatch' \) -print0
  )
  shellcheck "${shell_files[@]}"

  systemd_verify_root="$(mktemp -d /tmp/mixli-systemd-verify.XXXXXX)"
  install -d "$systemd_verify_root/opt/mixli/bin" \
    "$systemd_verify_root/etc/systemd/system" "$systemd_verify_root/usr/bin"
  install -m 0755 "${shell_files[@]}" "$systemd_verify_root/opt/mixli/bin/"
  install -m 0755 /usr/bin/true "$systemd_verify_root/usr/bin/docker"
  install -m 0644 "$CHECKOUT"/ops/production/systemd/* \
    "$systemd_verify_root/etc/systemd/system/"
  systemd-analyze verify --recursive-errors=no --root="$systemd_verify_root" \
    "$systemd_verify_root"/etc/systemd/system/*
  rm -rf -- "$systemd_verify_root"
  systemd_verify_root=''

  if [[ -f "$CHECKOUT/ops/production/prometheus/prometheus.yml" ]]; then
    prometheus_verify_root="$(mktemp -d /tmp/mixli-prometheus-verify.XXXXXX)"
    chmod 0755 "$prometheus_verify_root"
    install -m 0644 "$CHECKOUT/ops/production/prometheus/prometheus.yml" \
      "$CHECKOUT/ops/production/prometheus/rules.yml" "$prometheus_verify_root/"
    docker run --rm -v "$prometheus_verify_root:/etc/prometheus:ro" \
      --entrypoint promtool "$PROMETHEUS_IMAGE" \
      check config /etc/prometheus/prometheus.yml
    docker run --rm -v "$prometheus_verify_root:/etc/prometheus:ro" \
      --entrypoint promtool "$PROMETHEUS_IMAGE" \
      check rules /etc/prometheus/rules.yml
    rm -rf -- "$prometheus_verify_root"
    prometheus_verify_root=''
  fi
  if [[ -f "$CHECKOUT/ops/production/alertmanager/alertmanager.yml" ]]; then
    alertmanager_verify_root="$(mktemp -d /tmp/mixli-alertmanager-verify.XXXXXX)"
    chmod 0755 "$alertmanager_verify_root"
    install -d -m 0755 "$alertmanager_verify_root/secrets"
    install -m 0644 "$CHECKOUT/ops/production/alertmanager/alertmanager.yml" \
      "$alertmanager_verify_root/alertmanager.yml"
    printf '%s\n' 'https://example.invalid/hooks/ci' \
      >"$alertmanager_verify_root/secrets/webhook-url"
    chmod 0644 "$alertmanager_verify_root/secrets/webhook-url"
    docker run --rm -v "$alertmanager_verify_root:/etc/alertmanager:ro" \
      --entrypoint amtool "$ALERTMANAGER_IMAGE" \
      check-config /etc/alertmanager/alertmanager.yml
    rm -rf -- "$alertmanager_verify_root"
    alertmanager_verify_root=''
  fi
}

wait_for_postgres() {
  local attempt status
  for ((attempt = 1; attempt <= 60; attempt++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$postgres_container")"
    [[ "$status" == 'healthy' ]] && return 0
    [[ "$status" == 'unhealthy' ]] && return 1
    sleep 2
  done
  return 1
}

api_postgres_integration() {
  network="mixli-ci-$SHORT_SHA"
  postgres_container="mixli-ci-postgres-$SHORT_SHA"

  docker network create "$network" >/dev/null
  docker run -d --name "$postgres_container" --network "$network" --network-alias postgres \
    --tmpfs /var/lib/postgresql:rw,nosuid,nodev,size=2g \
    -e POSTGRES_DB=mosaic -e POSTGRES_USER=mosaic -e POSTGRES_PASSWORD=mosaic \
    --health-cmd 'pg_isready -U mosaic -d mosaic' --health-interval 2s \
    --health-timeout 3s --health-retries 30 postgres:18.3-alpine >/dev/null
  wait_for_postgres

  docker run --rm --network "$network" \
    -e DATABASE_URL=postgres://mosaic:mosaic@postgres:5432/mosaic \
    -w /workspace/apps/api "$API_CI_IMAGE" bash -lc \
    'set -Eeuo pipefail
     npm run typecheck
     npm test
     npm run build'

  docker rm -f "$postgres_container" >/dev/null
  postgres_container=''
  docker network rm "$network" >/dev/null
  network=''
}

flutter_workspace() {
  docker run --rm --user 0:0 -e HOME=/tmp/flutter-home \
    -v "$CHECKOUT:/workspace" -w /workspace "$FLUTTER_IMAGE" bash -c \
    'set -Eeuo pipefail
     flutter pub get --enforce-lockfile
     dart format --output=none --set-exit-if-changed .
     flutter analyze
     (cd packages/play_schema && dart test)
     (cd packages/play_engine && dart test)
     (cd packages/analytics_contract && dart test)
     (cd packages/local_state && dart test --reporter=expanded)
     (cd packages/play_flutter && flutter test)
     (cd packages/platform_contracts && dart test)
     (cd packages/platform_flutter && flutter test)
     (cd apps/mosaic_app && flutter test)
     (cd apps/mosaic_app && flutter build web --release --pwa-strategy=none)'
}

platform_declarations() {
  docker run --rm -i -v "$CHECKOUT:/repo:ro" -w /repo python:3.14.1-slim python3 - <<'PY'
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

info_path = Path('apps/mosaic_app/ios/Runner/Info.plist')
privacy_path = Path('apps/mosaic_app/ios/Runner/PrivacyInfo.xcprivacy')
with info_path.open('rb') as handle:
    info = plistlib.load(handle)
with privacy_path.open('rb') as handle:
    plistlib.load(handle)

for forbidden in (
    'NSLocationAlwaysAndWhenInUseUsageDescription',
    'NSLocationAlwaysUsageDescription',
    'NSLocationWhenInUseUsageDescription',
):
    if forbidden in info:
        raise SystemExit(f'Unexpected v1 location purpose: {forbidden}')

required_ios = {
    'NSCameraUsageDescription',
    'NSMicrophoneUsageDescription',
    'NSPhotoLibraryUsageDescription',
}

def parse_strings(path: str) -> dict[str, str]:
    text = Path(path).read_text(encoding='utf-8')
    pairs = dict(re.findall(r'^\s*"([^"]+)"\s*=\s*"([^"]+)";\s*$', text, flags=re.MULTILINE))
    missing = required_ios - pairs.keys()
    if missing:
        raise SystemExit(f'{path} missing {sorted(missing)}')
    return pairs

ios_en = parse_strings('apps/mosaic_app/ios/Runner/en.lproj/InfoPlist.strings')
ios_es = parse_strings('apps/mosaic_app/ios/Runner/es.lproj/InfoPlist.strings')
if any(ios_en[key] == ios_es[key] for key in required_ios):
    raise SystemExit('iOS purpose copy was not localized')

required_android = {
    'app_name',
    'permission_camera_purpose',
    'permission_microphone_purpose',
    'permission_notifications_purpose',
}

def parse_android(path: str) -> dict[str, str]:
    root = ET.parse(path).getroot()
    values = {node.attrib['name']: (node.text or '').strip() for node in root.findall('string')}
    missing = required_android - values.keys()
    if missing or any(not values[key] for key in required_android):
        raise SystemExit(f'{path} has incomplete purpose copy')
    return values

android_en = parse_android('apps/mosaic_app/android/app/src/main/res/values/strings.xml')
android_es = parse_android('apps/mosaic_app/android/app/src/main/res/values-es/strings.xml')
purpose_keys = required_android - {'app_name'}
if any(android_en[key] == android_es[key] for key in purpose_keys):
    raise SystemExit('Android purpose copy was not localized')
PY

  local manifest="$CHECKOUT/apps/mosaic_app/android/app/src/main/AndroidManifest.xml"
  grep -q 'android.permission.INTERNET' "$manifest"
  grep -q 'android.permission.CAMERA' "$manifest"
  grep -q 'android.permission.RECORD_AUDIO' "$manifest"
  grep -q 'android.permission.POST_NOTIFICATIONS' "$manifest"
  grep -q 'android:label="@string/app_name"' "$manifest"
  if grep -Eq 'READ_MEDIA_IMAGES|READ_MEDIA_VIDEO|READ_EXTERNAL_STORAGE|ACCESS_FINE_LOCATION|ACCESS_COARSE_LOCATION' "$manifest"; then
    return 1
  fi
  grep -q 'PrivacyInfo.xcprivacy in Resources' "$CHECKOUT/apps/mosaic_app/ios/Runner.xcodeproj/project.pbxproj"
  grep -q 'InfoPlist.strings in Resources' "$CHECKOUT/apps/mosaic_app/ios/Runner.xcodeproj/project.pbxproj"
  grep -q '^STRIP_STYLE = non-global$' "$CHECKOUT/apps/mosaic_app/ios/Flutter/Release.xcconfig"
  grep -q 'assets/packages/flutter_soloud/web/libflutter_soloud_plugin.js' "$CHECKOUT/apps/mosaic_app/web/index.html"
  grep -q 'assets/packages/flutter_soloud/web/init_module.dart.js' "$CHECKOUT/apps/mosaic_app/web/index.html"
}

production_builds() {
  docker image inspect "$API_IMAGE" "$FLUTTER_IMAGE" "$POSTGRES_IMAGE" >/dev/null
  [[ -f "$CHECKOUT/apps/mosaic_app/build/web/index.html" ]]
}

main() {
  validate_inputs
  trap cleanup EXIT
  run_stage source-integrity source_integrity
  run_stage infrastructure-contracts infrastructure_contracts
  run_stage api-postgres-integration api_postgres_integration
  run_stage flutter-workspace flutter_workspace
  run_stage platform-declarations platform_declarations
  run_stage production-builds production_builds
}

main
