#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly CHECKOUT="${1-}"
readonly SHA="${2-}"
readonly TEST_MODE="${MIXLI_CI_TEST_MODE:-0}"
readonly RETAIN_RELEASE_IMAGES_REQUESTED="${MIXLI_CI_RETAIN_RELEASE_IMAGES:-${MIXLI_CI_RETAIN_POSTGRES_IMAGE:-0}}"
readonly SHORT_SHA="${SHA:0:12}"
readonly FLUTTER_IMAGE="${MIXLI_FLUTTER_CI_IMAGE:-mixli-flutter-builder:3.44.7}"
readonly POSTGRES_CI_IMAGE="mixli-postgres-ci:$SHA"
readonly API_CI_IMAGE="mixli-api-ci:$SHA"
readonly API_TEST_IMAGE="mixli-api-test:$SHA"
readonly PROMETHEUS_IMAGE="${MIXLI_PROMETHEUS_CI_IMAGE:-prom/prometheus:v3.5.5}"
readonly ALERTMANAGER_IMAGE="${MIXLI_ALERTMANAGER_CI_IMAGE:-prom/alertmanager:v0.32.1}"
readonly BUILDER_BATS=(
  "$CHECKOUT/ops/production/tests/ci_request.bats"
  "$CHECKOUT/ops/production/tests/deploy_dispatch.bats"
  "$CHECKOUT/ops/production/tests/deployment.bats"
  "$CHECKOUT/ops/production/tests/github_workflow.bats"
  "$CHECKOUT/ops/production/tests/hardening_contracts.bats"
  "$CHECKOUT/ops/production/tests/server_ci.bats"
  "$CHECKOUT/ops/production/tests/verify_script.bats"
)

network=''
postgres_container=''
flutter_volume=''
systemd_verify_root=''
alertmanager_verify_root=''
prometheus_verify_root=''
nginx_verify_root=''
retain_release_images=0

die_usage() {
  printf '%s\n' 'server-ci.sh requires an absolute checkout and exact lowercase commit SHA.' >&2
  exit 64
}

checkout_git() {
  runuser -u mixli-build -- git -c safe.directory="$CHECKOUT" -C "$CHECKOUT" "$@"
}

builder_exec() {
  runuser -u mixli-build -- "$@"
}

cleanup() {
  local status="$1" cleanup_status=0 image image_cleanup_status
  trap - EXIT
  set +e
  docker image rm "$API_TEST_IMAGE" >/dev/null 2>&1 || true
  if [[ "$retain_release_images" != '1' ]]; then
    for image in "$API_CI_IMAGE" "$POSTGRES_CI_IMAGE"; do
      docker image rm --force "$image" >/dev/null 2>&1
      image_cleanup_status=$?
      if [[ "$image_cleanup_status" -ne 0 ]]; then
        printf 'Failed to remove exact CI image tag %s.\n' "$image" >&2
        [[ "$cleanup_status" -ne 0 ]] || cleanup_status="$image_cleanup_status"
      fi
    done
  fi
  if [[ -n "$postgres_container" ]]; then
    docker rm -f "$postgres_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$network" ]]; then
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
  if [[ -n "$flutter_volume" ]]; then
    docker volume rm --force "$flutter_volume" >/dev/null 2>&1 || true
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
  if [[ "$nginx_verify_root" == /tmp/mixli-nginx-verify.* && -d "$nginx_verify_root" ]]; then
    rm -rf -- "$nginx_verify_root"
  fi
  if [[ "$status" -ne 0 ]]; then
    exit "$status"
  fi
  exit "$cleanup_status"
}

validate_inputs() {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die_usage
  [[ "$RETAIN_RELEASE_IMAGES_REQUESTED" == '0' ||
    "$RETAIN_RELEASE_IMAGES_REQUESTED" == '1' ]] || die_usage
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
  if [[ "$TEST_MODE" == '1' ]]; then
    [[ "${MIXLI_CI_TEST_FAIL_STAGE:-}" != "$name" ]]
  else
    "$implementation"
  fi
}

source_integrity() {
  checkout_git clean -ffdqx
  checkout_git reset --hard "$SHA" >/dev/null
  checkout_git diff --check
  [[ -z "$(checkout_git status --porcelain --untracked-files=all)" ]]
}

isolated_nginx_contract() {
  nginx_verify_root="$(mktemp -d /tmp/mixli-nginx-verify.XXXXXX)"
  install -d -m 0755 "$nginx_verify_root/config/conf.d" \
    "$nginx_verify_root/runtime" "$nginx_verify_root/tls"
  install -m 0644 "$CHECKOUT/ops/production/nginx/nginx.conf" \
    "$nginx_verify_root/config/nginx.conf"
  install -m 0644 "$CHECKOUT/ops/production/nginx/conf.d/mixli.conf" \
    "$nginx_verify_root/config/conf.d/mixli.conf"
  install -m 0644 "$CHECKOUT/ops/production/nginx/cloudflare-real-ip.conf.example" \
    "$nginx_verify_root/config/cloudflare-real-ip.conf"
  install -m 0644 "$CHECKOUT/ops/production/runtime/api-upstream.example.conf" \
    "$nginx_verify_root/runtime/api-upstream.conf"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mixli.app \
    -keyout "$nginx_verify_root/tls/origin.key" \
    -out "$nginx_verify_root/tls/origin.pem" >/dev/null 2>&1
  chmod -R a=rX "$nginx_verify_root"
  docker run --rm --network none --read-only --user 101:101 \
    --cap-drop ALL --security-opt no-new-privileges \
    --add-host api-blue-1:127.0.0.1 \
    --add-host api-blue-2:127.0.0.1 \
    --add-host grafana:127.0.0.1 \
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,mode=1777 \
    --tmpfs /var/run:rw,noexec,nosuid,nodev,mode=1777 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
    -v "$nginx_verify_root/config:/etc/nginx/mixli:ro" \
    -v "$nginx_verify_root/runtime:/etc/nginx/runtime:ro" \
    -v "$nginx_verify_root/tls:/etc/nginx/tls:ro" \
    nginx:1.28.0-alpine nginx -t -c /etc/nginx/mixli/nginx.conf
  rm -rf -- "$nginx_verify_root"
  nginx_verify_root=''
}

infrastructure_contracts() {
  docker build --target ci -f "$CHECKOUT/apps/api/Dockerfile" \
    -t "$API_TEST_IMAGE" "$CHECKOUT"
  docker build -f "$CHECKOUT/apps/api/Dockerfile" -t "$API_CI_IMAGE" "$CHECKOUT"
  docker build -f "$CHECKOUT/ops/production/flutter/Dockerfile" \
    -t "$FLUTTER_IMAGE" "$CHECKOUT"
  docker build -f "$CHECKOUT/ops/production/postgres/Dockerfile" \
    -t "$POSTGRES_CI_IMAGE" "$CHECKOUT/ops/production/postgres"

  (
    cd "$CHECKOUT"
    docker compose --env-file ops/production/env/production.env.example \
      -f ops/production/compose.yaml config --quiet
  )
  isolated_nginx_contract
  export MIXLI_HOST_REPO="$CHECKOUT"
  builder_exec bats "${BUILDER_BATS[@]}"

  mapfile -d '' shell_files < <(
    builder_exec find "$CHECKOUT/ops/production/bin" -maxdepth 1 -type f \
      \( -name '*.sh' -o -name 'deploy-dispatch' \) -print0
  )
  builder_exec shellcheck "${shell_files[@]}"

  systemd_verify_root="$(builder_exec mktemp -d /tmp/mixli-systemd-verify.XXXXXX)"
  builder_exec install -d "$systemd_verify_root/opt/mixli/bin" \
    "$systemd_verify_root/etc/systemd/system" "$systemd_verify_root/usr/bin"
  builder_exec install -m 0755 "${shell_files[@]}" "$systemd_verify_root/opt/mixli/bin/"
  builder_exec install -m 0755 /usr/bin/true "$systemd_verify_root/usr/bin/docker"
  builder_exec install -m 0644 "$CHECKOUT"/ops/production/systemd/* \
    "$systemd_verify_root/etc/systemd/system/"
  builder_exec systemd-analyze verify --recursive-errors=no --root="$systemd_verify_root" \
    "$systemd_verify_root"/etc/systemd/system/*
  rm -rf -- "$systemd_verify_root"
  systemd_verify_root=''

  if [[ -f "$CHECKOUT/ops/production/prometheus/prometheus.yml" ]]; then
    prometheus_verify_root="$(builder_exec mktemp -d /tmp/mixli-prometheus-verify.XXXXXX)"
    builder_exec chmod 0755 "$prometheus_verify_root"
    builder_exec install -m 0644 "$CHECKOUT/ops/production/prometheus/prometheus.yml" \
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
    alertmanager_verify_root="$(builder_exec mktemp -d /tmp/mixli-alertmanager-verify.XXXXXX)"
    builder_exec chmod 0755 "$alertmanager_verify_root"
    builder_exec install -d -m 0755 "$alertmanager_verify_root/secrets"
    builder_exec install -m 0644 "$CHECKOUT/ops/production/alertmanager/alertmanager.yml" \
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
    -w /workspace/apps/api "$API_TEST_IMAGE" bash -lc \
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
  local builder_uid builder_gid
  builder_uid="$(id -u mixli-build)"
  builder_gid="$(id -g mixli-build)"
  flutter_volume="mixli-flutter-workspace-$SHORT_SHA"
  docker volume create "$flutter_volume" >/dev/null
  docker run --rm -v "$CHECKOUT:/source:ro" -v "$flutter_volume:/workspace" \
    alpine:3.22 sh -c 'cp -a /source/. /workspace/ && chown -R 1000:1000 /workspace'
  docker run --rm -v "$flutter_volume:/workspace" -w /workspace \
    "$FLUTTER_IMAGE" bash -c \
    'set -Eeuo pipefail
     flutter pub get --offline --enforce-lockfile
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
  install -d -o mixli-build -g mixli-build \
    "$CHECKOUT/apps/mosaic_app/build/web"
  docker run --rm -v "$flutter_volume:/source:ro" \
    -v "$CHECKOUT/apps/mosaic_app/build/web:/destination" alpine:3.22 sh -c \
    "cp -a /source/apps/mosaic_app/build/web/. /destination/ && chown -R $builder_uid:$builder_gid /destination"
  docker volume rm --force "$flutter_volume" >/dev/null
  flutter_volume=''
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
  builder_exec grep -q 'android.permission.INTERNET' "$manifest"
  builder_exec grep -q 'android.permission.CAMERA' "$manifest"
  builder_exec grep -q 'android.permission.RECORD_AUDIO' "$manifest"
  builder_exec grep -q 'android.permission.POST_NOTIFICATIONS' "$manifest"
  builder_exec grep -q 'android:label="@string/app_name"' "$manifest"
  if builder_exec grep -Eq 'READ_MEDIA_IMAGES|READ_MEDIA_VIDEO|READ_EXTERNAL_STORAGE|ACCESS_FINE_LOCATION|ACCESS_COARSE_LOCATION' "$manifest"; then
    return 1
  fi
  builder_exec grep -q 'PrivacyInfo.xcprivacy in Resources' "$CHECKOUT/apps/mosaic_app/ios/Runner.xcodeproj/project.pbxproj"
  builder_exec grep -q 'InfoPlist.strings in Resources' "$CHECKOUT/apps/mosaic_app/ios/Runner.xcodeproj/project.pbxproj"
  builder_exec grep -q '^STRIP_STYLE = non-global$' "$CHECKOUT/apps/mosaic_app/ios/Flutter/Release.xcconfig"
  builder_exec grep -q 'assets/packages/flutter_soloud/web/libflutter_soloud_plugin.js' "$CHECKOUT/apps/mosaic_app/web/index.html"
  builder_exec grep -q 'assets/packages/flutter_soloud/web/init_module.dart.js' "$CHECKOUT/apps/mosaic_app/web/index.html"
}

production_builds() {
  docker image inspect "$API_CI_IMAGE" "$FLUTTER_IMAGE" "$POSTGRES_CI_IMAGE" >/dev/null
  builder_exec test -f "$CHECKOUT/apps/mosaic_app/build/web/index.html"
}

main() {
  validate_inputs
  trap 'cleanup $?' EXIT
  run_stage source-integrity source_integrity
  run_stage infrastructure-contracts infrastructure_contracts
  run_stage api-postgres-integration api_postgres_integration
  run_stage flutter-workspace flutter_workspace
  run_stage platform-declarations platform_declarations
  run_stage production-builds production_builds
  if [[ "$RETAIN_RELEASE_IMAGES_REQUESTED" == '1' ]]; then
    retain_release_images=1
  fi
}

main
