#!/usr/bin/env bats

setup() {
  IMAGE="${MIXLI_API_IMAGE:-mixli-api:test}"
}

@test "uses Node 24" {
  run docker run --rm --entrypoint node "$IMAGE" --version

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^v24\. ]]
}

@test "runs as a non-root user" {
  run docker run --rm --entrypoint sh "$IMAGE" -c 'test "$(id -u)" -ne 0'

  [ "$status" -eq 0 ]
}

@test "contains the compiled server and migration artifacts" {
  run docker run --rm --entrypoint sh "$IMAGE" -c \
    'test -f dist/server.js && test -f dist/db/migrate.js && test -d migrations'

  [ "$status" -eq 0 ]
}

@test "omits the tsx development executable" {
  run docker run --rm --entrypoint sh "$IMAGE" -c \
    'test ! -x node_modules/.bin/tsx'

  [ "$status" -eq 0 ]
}

@test "declares a readiness health check" {
  run docker image inspect \
    --format '{{json .Config.Healthcheck.Test}}' \
    "$IMAGE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"/ready"* ]]
}
