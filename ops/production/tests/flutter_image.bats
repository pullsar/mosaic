#!/usr/bin/env bats

setup() {
  IMAGE="${MIXLI_FLUTTER_IMAGE:-mixli-flutter-builder:test}"
  DOCKERFILE="${MIXLI_FLUTTER_DOCKERFILE:-ops/production/flutter/Dockerfile}"
}

@test "retries and resumes the pinned SDK download" {
  run grep -F -- '--retry 5' "$DOCKERFILE"
  [ "$status" -eq 0 ]

  run grep -F -- '--retry-all-errors' "$DOCKERFILE"
  [ "$status" -eq 0 ]

  run grep -F -- '--continue-at -' "$DOCKERFILE"
  [ "$status" -eq 0 ]
}

@test "pins Flutter 3.44.7 and Dart 3.12.2" {
  run docker run --rm "$IMAGE" flutter --version --machine

  [ "$status" -eq 0 ]
  [[ "$output" =~ \"frameworkVersion\"[[:space:]]*:[[:space:]]*\"3\.44\.7\" ]]
  [[ "$output" =~ \"dartSdkVersion\"[[:space:]]*:[[:space:]]*\"3\.12\.2\" ]]
}

@test "runs Flutter as a non-root user" {
  run docker run --rm --entrypoint sh "$IMAGE" -c 'test "$(id -u)" -ne 0'

  [ "$status" -eq 0 ]
}

@test "has web support enabled" {
  run docker run --rm "$IMAGE" flutter config --list

  [ "$status" -eq 0 ]
  [[ "$output" == *"enable-web: true"* ]]
}

@test "pins the Android and browser toolchain inside the Flutter image" {
  grep -Fq 'ARG ANDROID_CMDLINE_TOOLS_VERSION=15859902' "$DOCKERFILE"
  grep -Fq 'ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583' "$DOCKERFILE"
  grep -Fq 'CHROME_EXECUTABLE=/usr/local/bin/chromium-ci' "$DOCKERFILE"
  grep -Fq -- '--no-sandbox' "$DOCKERFILE"
  grep -Fq "'platforms/android-35'" "$DOCKERFILE"
  grep -Fq "'platforms/android-36'" "$DOCKERFILE"
  grep -Fq 'platforms/android-37.0' "$DOCKERFILE"
  grep -Fq 'build-tools/36.0.0' "$DOCKERFILE"
  grep -Fq 'build-tools/37.0.0' "$DOCKERFILE"
  grep -Fq 'ndk/28.2.13676358' "$DOCKERFILE"

  run docker run --rm "$IMAGE" bash -lc '
    test "$ANDROID_SDK_ROOT" = /opt/android-sdk
    java -version
    "$CHROME_EXECUTABLE" --version
    test -x "$CHROME_EXECUTABLE"
    test -x /opt/android-sdk/platform-tools/adb
    test -x /opt/android-sdk/build-tools/36.0.0/aapt2
    test -x /opt/android-sdk/build-tools/37.0.0/aapt2
    test -d /opt/android-sdk/platforms/android-35
    test -d /opt/android-sdk/platforms/android-36
    test -d /opt/android-sdk/platforms/android-37.0
    test -d /opt/android-sdk/ndk/28.2.13676358
  '

  [ "$status" -eq 0 ]
}

@test "caches locked workspace packages and CI resolves them offline" {
  grep -Fq 'flutter pub get --enforce-lockfile' "$DOCKERFILE"
  grep -Fq 'pubspec.lock' "$DOCKERFILE"
  grep -Fq 'packages/event_delivery/pubspec.yaml' "$DOCKERFILE"
  grep -Fq 'flutter pub get --offline --enforce-lockfile' \
    ops/production/bin/server-ci.sh
}
