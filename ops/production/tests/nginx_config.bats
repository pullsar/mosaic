#!/usr/bin/env bats

setup_file() {
  : "${MIXLI_HOST_REPO:?Set MIXLI_HOST_REPO to the host-visible repository path}"
  SUFFIX="$$"
  export NETWORK="mixli-nginx-test-${SUFFIX}"
  export NGINX_CONTAINER="mixli-nginx-${SUFFIX}"
  export TLS_DIR
  TLS_DIR="$(mktemp -d /tmp/mixli-nginx-tls.XXXXXX)"
  export WEB_VOLUME="mixli-nginx-web-${SUFFIX}"
  export BLUE1="mixli-blue1-${SUFFIX}"
  export BLUE2="mixli-blue2-${SUFFIX}"
  export GRAFANA="mixli-grafana-${SUFFIX}"

  docker network create "$NETWORK" >/dev/null
  docker volume create "$WEB_VOLUME" >/dev/null

  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mixli.app \
    -keyout "$TLS_DIR/origin.key" -out "$TLS_DIR/origin.pem" >/dev/null 2>&1
  chmod 0644 "$TLS_DIR/origin.key" "$TLS_DIR/origin.pem"
  docker run --rm -v "$WEB_VOLUME:/web" alpine:3.22 sh -c \
    "mkdir -p /web/assets && printf 'mixli-spa' >/web/index.html && printf 'asset' >/web/assets/main.abcdef12.js"

  docker run -d --name "$BLUE1" --network "$NETWORK" --network-alias api-blue-1 nginx:1.28.0-alpine sh -c \
    "sed -i 's/listen       80;/listen 8080;/' /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'" >/dev/null
  docker run -d --name "$BLUE2" --network "$NETWORK" --network-alias api-blue-2 nginx:1.28.0-alpine sh -c \
    "sed -i 's/listen       80;/listen 8080;/' /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'" >/dev/null
  docker run -d --name "$GRAFANA" --network "$NETWORK" --network-alias grafana nginx:1.28.0-alpine >/dev/null

  docker run -d --name "$NGINX_CONTAINER" --network "$NETWORK" \
    -v "$MIXLI_HOST_REPO/ops/production/nginx:/etc/nginx/mixli:ro" \
    -v "$MIXLI_HOST_REPO/ops/production/nginx/cloudflare-real-ip.conf.example:/etc/nginx/mixli/cloudflare-real-ip.conf:ro" \
    -v "$MIXLI_HOST_REPO/ops/production/runtime/api-upstream.example.conf:/etc/nginx/runtime/api-upstream.conf:ro" \
    -v "$TLS_DIR:/etc/nginx/tls:ro" \
    -v "$WEB_VOLUME:/srv/mixli/current/web:ro" \
    nginx:1.28.0-alpine nginx -c /etc/nginx/mixli/nginx.conf -g 'daemon off;' >/dev/null

  for _ in $(seq 1 30); do
    docker exec "$NGINX_CONTAINER" wget -qO- --header='Host: api.mixli.app' http://127.0.0.1/nginx-health >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "$NGINX_CONTAINER" >&2
  return 1
}

teardown_file() {
  docker rm -f "$NGINX_CONTAINER" "$BLUE1" "$BLUE2" "$GRAFANA" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm -f "$WEB_VOLUME" >/dev/null 2>&1 || true
  if [[ "$TLS_DIR" == /tmp/mixli-nginx-tls.* && -d "$TLS_DIR" ]]; then
    rm -rf -- "$TLS_DIR"
  fi
}

curl_origin() {
  local path="${!#}"
  local args=("${@:1:$#-1}")
  docker run --rm --network "$NETWORK" curlimages/curl:8.16.0 -sk "${args[@]}" "https://$NGINX_CONTAINER$path"
}

@test "configuration validates in the production image" {
  run docker exec "$NGINX_CONTAINER" nginx -t
  [ "$status" -eq 0 ]
}

@test "apex serves SPA fallback and revalidates index" {
  run curl_origin -D - -H 'Host: mixli.app' /unknown/client/route
  [ "$status" -eq 0 ]
  [[ "$output" == *"mixli-spa"* ]]
  [[ "${output,,}" == *"cache-control: no-cache, no-store, must-revalidate"* ]]
}

@test "hashed web assets are immutable" {
  run curl_origin -D - -o /dev/null -H 'Host: mixli.app' /assets/main.abcdef12.js
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *"cache-control: public, max-age=31536000, immutable"* ]]
}

@test "www redirects permanently to the apex and preserves the URI" {
  run curl_origin -I -H 'Host: www.mixli.app' /hello?from=test
  [ "$status" -eq 0 ]
  [[ "$output" == *"308"* ]]
  [[ "${output,,}" == *"location: https://mixli.app/hello?from=test"* ]]
}

@test "API origin health does not depend on the application" {
  run curl_origin -H 'Host: api.mixli.app' /nginx-health
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "API metrics are not exposed through the public origin" {
  [ "$(grep -c 'location = /metrics' ops/production/nginx/conf.d/mixli.conf)" -eq 2 ]
  run curl_origin -o /dev/null -w '%{http_code}' -H 'Host: api.mixli.app' /metrics
  [ "$status" -eq 0 ]
  [ "$output" = "404" ]
}

@test "API proxies to the active pool" {
  run curl_origin -H 'Host: api.mixli.app' /
  [ "$status" -eq 0 ]
  [[ "$output" == *"Welcome to nginx!"* ]]
}

@test "operations host denies requests without a Cloudflare Access assertion" {
  run curl_origin -o /dev/null -w '%{http_code}' -H 'Host: ops.mixli.app' /
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "web permissions allow same-origin camera and microphone only" {
  local config="ops/production/nginx/conf.d/mixli.conf"
  run grep -F 'Permissions-Policy "camera=(self), microphone=(self), geolocation=()"' "$config"
  [ "$status" -eq 0 ]
}

@test "proxy policy preserves request identity, safe retry, buffering, and WebSockets" {
  local config="ops/production/nginx/conf.d/mixli.conf"
  run grep -E 'proxy_set_header[[:space:]]+X-Request-ID[[:space:]]+\$mixli_request_id' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'proxy_next_upstream[[:space:]]+error[[:space:]]+timeout[[:space:]]+http_502[[:space:]]+http_503[[:space:]]+http_504' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'proxy_buffering[[:space:]]+on' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'proxy_set_header[[:space:]]+Upgrade[[:space:]]+\$http_upgrade' "$config"
  [ "$status" -eq 0 ]
  run grep -E 'proxy_set_header[[:space:]]+Connection[[:space:]]+\$connection_upgrade' "$config"
  [ "$status" -eq 0 ]
}
