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

@test "caches locked workspace packages and CI resolves them offline" {
  grep -Fq 'flutter pub get --enforce-lockfile' "$DOCKERFILE"
  grep -Fq 'pubspec.lock' "$DOCKERFILE"
  grep -Fq 'flutter pub get --offline --enforce-lockfile' \
    ops/production/bin/server-ci.sh
}
