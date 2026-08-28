#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly TEST_MODE="${MIXLI_CF_TEST_MODE:-0}"
readonly IPV4_SOURCE="${MIXLI_CF_IPV4_SOURCE:-https://www.cloudflare.com/ips-v4}"
readonly IPV6_SOURCE="${MIXLI_CF_IPV6_SOURCE:-https://www.cloudflare.com/ips-v6}"
readonly TEST_OUTPUT="${MIXLI_CF_TEST_OUTPUT:-}"
readonly LOCK_FILE="${MIXLI_CF_LOCK_FILE:-/run/lock/mixli-cloudflare-ips.lock}"

work_dir=''

cleanup() {
  if [[ "$work_dir" == /tmp/mixli-cloudflare-ips.* && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
  if [[ "$TEST_MODE" != '1' ]]; then
    ipset destroy mixli_cf4_next >/dev/null 2>&1 || true
    ipset destroy mixli_cf6_next >/dev/null 2>&1 || true
  fi
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
  if grep -Evq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' "$v4"; then
    return 1
  fi
  if grep -Evq '^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' "$v6"; then
    return 1
  fi
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

ensure_filter_chain() {
  local command="$1" set_name="$2" interface="$3"
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]]
  "$command" -N MIXLI-CLOUDFLARE 2>/dev/null || true
  "$command" -F MIXLI-CLOUDFLARE
  "$command" -A MIXLI-CLOUDFLARE -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  "$command" -A MIXLI-CLOUDFLARE -p tcp -m multiport --dports 80,443 \
    -m set --match-set "$set_name" src -j RETURN
  "$command" -A MIXLI-CLOUDFLARE -p tcp -m multiport --dports 80,443 -j REJECT
  "$command" -A MIXLI-CLOUDFLARE -j RETURN
  # Restrict only traffic entering from the public interface. An unconditional
  # DOCKER-USER jump also matches container egress to destination ports 80/443.
  "$command" -D DOCKER-USER -j MIXLI-CLOUDFLARE 2>/dev/null || true
  "$command" -C DOCKER-USER -i "$interface" -j MIXLI-CLOUDFLARE 2>/dev/null || \
    "$command" -I DOCKER-USER 1 -i "$interface" -j MIXLI-CLOUDFLARE
}

install_sets() {
  local v4="$1" v6="$2" cidr interface_v4 interface_v6
  ipset create mixli_cf4_next hash:net family inet maxelem 256
  while IFS= read -r cidr; do ipset add mixli_cf4_next "$cidr"; done <"$v4"
  ipset create mixli_cf6_next hash:net family inet6 maxelem 256
  while IFS= read -r cidr; do ipset add mixli_cf6_next "$cidr"; done <"$v6"

  ipset create mixli_cloudflare_v4 hash:net family inet maxelem 256 -exist
  ipset create mixli_cloudflare_v6 hash:net family inet6 maxelem 256 -exist
  ipset swap mixli_cf4_next mixli_cloudflare_v4
  ipset swap mixli_cf6_next mixli_cloudflare_v6
  ipset destroy mixli_cf4_next
  ipset destroy mixli_cf6_next
  interface_v4="$(ip -4 route show default | awk '$1 == "default" {print $5; exit}')"
  interface_v6="$(ip -6 route show default | awk '$1 == "default" {print $5; exit}')"
  [[ -n "$interface_v4" ]]
  [[ -n "$interface_v6" ]] || interface_v6="$interface_v4"
  ensure_filter_chain iptables mixli_cloudflare_v4 "$interface_v4"
  ensure_filter_chain ip6tables mixli_cloudflare_v6 "$interface_v6"
}

main() {
  local v4 v6
  if [[ "$TEST_MODE" != '1' ]]; then
    [[ "$EUID" -eq 0 ]]
    install -d -m 0750 "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 75
  else
    [[ -n "$TEST_OUTPUT" && "$TEST_OUTPUT" == /* ]]
  fi

  work_dir="$(mktemp -d /tmp/mixli-cloudflare-ips.XXXXXX)"
  trap cleanup EXIT
  v4="$work_dir/ips-v4"
  v6="$work_dir/ips-v6"
  fetch_list "$IPV4_SOURCE" "$v4"
  fetch_list "$IPV6_SOURCE" "$v6"
  validate_lists "$v4" "$v6"

  if [[ "$TEST_MODE" == '1' ]]; then
    render_contract "$v4" "$v6" "$TEST_OUTPUT"
  else
    install_sets "$v4" "$v6"
  fi
}

main
