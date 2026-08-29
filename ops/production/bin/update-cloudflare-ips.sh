#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly TEST_MODE="${MIXLI_CF_TEST_MODE:-0}"
readonly IPV4_SOURCE="${MIXLI_CF_IPV4_SOURCE:-https://www.cloudflare.com/ips-v4}"
readonly IPV6_SOURCE="${MIXLI_CF_IPV6_SOURCE:-https://www.cloudflare.com/ips-v6}"
readonly TEST_OUTPUT="${MIXLI_CF_TEST_OUTPUT:-}"
readonly LOCK_FILE="${MIXLI_CF_LOCK_FILE:-/run/lock/mixli-cloudflare-ips.lock}"
readonly LAST_KNOWN_GOOD="${MIXLI_CF_LAST_KNOWN_GOOD:-/etc/mixli/cloudflare/firewall.nft}"
readonly REAL_IP_CONFIG="${MIXLI_CF_REAL_IP_CONFIG:-/etc/mixli/nginx/cloudflare-real-ip.conf}"
readonly COMPOSE_FILE="${MIXLI_COMPOSE_FILE:-/srv/mixli/runtime/compose.yaml}"
readonly ENV_FILE="${MIXLI_ENV_FILE:-/etc/mixli/env/production.env}"

work_dir=''

cleanup() {
  [[ "$work_dir" != /tmp/mixli-cloudflare-ips.* || ! -d "$work_dir" ]] || rm -rf -- "$work_dir"
}

fetch_list() {
  local source="$1" destination="$2"
  if [[ "$TEST_MODE" == '1' ]]; then
    cp -- "$source" "$destination"
  else
    curl --fail --silent --show-error --location --max-time 30 \
      --retry 4 --retry-all-errors "$source" -o "$destination"
  fi
  sed -i 's/\r$//' "$destination"
  sed -i '/^[[:space:]]*$/d' "$destination"
}

validate_lists() {
  local v4="$1" v6="$2"
  [[ -s "$v4" && -s "$v6" ]]
  ! grep -Evq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' "$v4"
  ! grep -Evq '^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' "$v6"
  grep -q '/' "$v4"
  grep -q ':' "$v6"
}

render_contract() {
  local v4="$1" v6="$2" destination="$3" temporary
  temporary="$destination.$$.tmp"
  {
    printf '%s\n' '[ipv4]'
    sort -u "$v4"
    printf '%s\n' '[ipv6]'
    sort -u "$v6"
    printf '%s\n' '[policy]' 'ssh=allow' 'docker-ports=80,443' 'source=cloudflare-only'
  } >"$temporary"
  mv -fT "$temporary" "$destination"
}

render_nft() {
  local v4="$1" v6="$2" interface="$3" destination="$4" cidr separator
  {
    printf '%s\n' 'destroy table inet mixli_cloudflare' 'table inet mixli_cloudflare {'
    printf '%s' '  set cloudflare_v4 { type ipv4_addr; flags interval; elements = { '
    separator=''
    while IFS= read -r cidr; do printf '%s%s' "$separator" "$cidr"; separator=', '; done < <(sort -u "$v4")
    printf '%s\n' ' } }'
    printf '%s' '  set cloudflare_v6 { type ipv6_addr; flags interval; elements = { '
    separator=''
    while IFS= read -r cidr; do printf '%s%s' "$separator" "$cidr"; separator=', '; done < <(sort -u "$v6")
    printf '%s\n' ' } }'
    printf '%s\n' \
      '  chain forward {' \
      '    type filter hook forward priority -10; policy accept;' \
      '    ct state established,related accept' \
      "    iifname \"$interface\" tcp dport { 80, 443 } ip saddr @cloudflare_v4 accept" \
      "    iifname \"$interface\" tcp dport { 80, 443 } ip6 saddr @cloudflare_v6 accept" \
      "    iifname \"$interface\" tcp dport { 80, 443 } reject" \
      '  }' '}'
  } >"$destination"
}

render_real_ip() {
  local v4="$1" v6="$2" destination="$3" cidr
  {
    while IFS= read -r cidr; do printf 'set_real_ip_from %s;\n' "$cidr"; done < <(sort -u "$v4")
    while IFS= read -r cidr; do printf 'set_real_ip_from %s;\n' "$cidr"; done < <(sort -u "$v6")
    printf '%s\n' 'real_ip_header CF-Connecting-IP;' 'real_ip_recursive on;'
  } >"$destination"
}

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

install_real_ip() {
  local generated="$1" candidate_real_ip validation_config container_id previous=''
  install -d -m 0755 "$(dirname "$REAL_IP_CONFIG")"
  candidate_real_ip="$(dirname "$REAL_IP_CONFIG")/.cloudflare-real-ip.candidate.$$"
  validation_config="$(dirname "$REAL_IP_CONFIG")/.cloudflare-real-ip-test.$$.conf"
  install -m 0644 "$generated" "$candidate_real_ip"
  container_id="$(compose ps -q nginx 2>/dev/null || true)"
  if [[ -n "$container_id" ]]; then
    printf 'events {}\nhttp { include /etc/nginx/mixli/%s; }\n' \
      "$(basename "$candidate_real_ip")" >"$validation_config"
    compose exec -T nginx nginx -t -c "/etc/nginx/mixli/$(basename "$validation_config")"
  fi
  if [[ -f "$REAL_IP_CONFIG" ]]; then
    previous="$(mktemp "$(dirname "$REAL_IP_CONFIG")/.cloudflare-real-ip.previous.XXXXXX")"
    cp -- "$REAL_IP_CONFIG" "$previous"
  fi
  mv -fT "$candidate_real_ip" "$(dirname "$REAL_IP_CONFIG")/cloudflare-real-ip.conf"
  rm -f -- "$validation_config"
  if [[ -n "$container_id" ]]; then
    if ! compose exec -T nginx nginx -t -c /etc/nginx/mixli/nginx.conf; then
      [[ -z "$previous" ]] || mv -fT "$previous" "$REAL_IP_CONFIG"
      return 1
    fi
    compose exec -T nginx nginx -s reload
  fi
  [[ -z "$previous" ]] || rm -f -- "$previous"
}

refresh() {
  local v4="$work_dir/ips-v4" v6="$work_dir/ips-v6"
  local candidate="$work_dir/firewall.nft" real_ip="$work_dir/cloudflare-real-ip.conf" interface
  fetch_list "$IPV4_SOURCE" "$v4"
  fetch_list "$IPV6_SOURCE" "$v6"
  validate_lists "$v4" "$v6"
  if [[ "$TEST_MODE" == '1' ]]; then
    render_contract "$v4" "$v6" "$TEST_OUTPUT"
    return 0
  fi
  interface="$(ip -4 route show default | awk '$1 == "default" {print $5; exit}')"
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]]
  render_nft "$v4" "$v6" "$interface" "$candidate"
  render_real_ip "$v4" "$v6" "$real_ip"
  nft -c -f "$candidate"
  nft -f "$candidate"
  install_real_ip "$real_ip"
  install -d -m 0750 "$(dirname "$LAST_KNOWN_GOOD")"
  install -m 0600 "$candidate" "$LAST_KNOWN_GOOD.$$.tmp"
  mv -fT "$LAST_KNOWN_GOOD.$$.tmp" "$LAST_KNOWN_GOOD"
}

main() {
  if [[ "$TEST_MODE" != '1' ]]; then
    [[ "$EUID" -eq 0 ]]
    install -d -m 0750 "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 75
    if [[ -s "$LAST_KNOWN_GOOD" ]]; then
      nft -c -f "$LAST_KNOWN_GOOD"
      nft -f "$LAST_KNOWN_GOOD"
    fi
  else
    [[ -n "$TEST_OUTPUT" && "$TEST_OUTPUT" == /* ]]
  fi
  work_dir="$(mktemp -d /tmp/mixli-cloudflare-ips.XXXXXX)"
  trap cleanup EXIT
  if ! refresh; then
    [[ "$TEST_MODE" != '1' && -s "$LAST_KNOWN_GOOD" ]] && return 0
    return 1
  fi
}

main
