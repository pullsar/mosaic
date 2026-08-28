#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  TEST_ROOT="$(mktemp -d)"
  printf '%s\n' 173.245.48.0/20 103.21.244.0/22 >"$TEST_ROOT/ips-v4"
  printf '%s\n' 2400:cb00::/32 2606:4700::/32 >"$TEST_ROOT/ips-v6"
  OUTPUT="$TEST_ROOT/rendered"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

run_ip_refresh() {
  env MIXLI_CF_TEST_MODE=1 \
    MIXLI_CF_IPV4_SOURCE="$TEST_ROOT/ips-v4" \
    MIXLI_CF_IPV6_SOURCE="$TEST_ROOT/ips-v6" \
    MIXLI_CF_TEST_OUTPUT="$OUTPUT" \
    "$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
}

@test "valid IPv4 and IPv6 lists render SSH-safe Docker origin policy" {
  run run_ip_refresh
  [ "$status" -eq 0 ]
  grep -Fq '[ipv4]' "$OUTPUT"
  grep -Fq '173.245.48.0/20' "$OUTPUT"
  grep -Fq '[ipv6]' "$OUTPUT"
  grep -Fq '2400:cb00::/32' "$OUTPUT"
  grep -Fq 'ssh=allow' "$OUTPUT"
  grep -Fq 'source=cloudflare-only' "$OUTPUT"
}

@test "invalid refresh never replaces the prior allowlist" {
  run_ip_refresh
  before="$(sha256sum "$OUTPUT")"
  printf '%s\n' not-a-cidr >"$TEST_ROOT/ips-v4"
  run run_ip_refresh
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$OUTPUT")" = "$before" ]
}

@test "provisioning test mode is semantically idempotent" {
  root="$TEST_ROOT/root"
  mkdir -p "$root"
  run env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  [ "$status" -eq 0 ]
  first="$(find "$root" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  run env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  [ "$status" -eq 0 ]
  second="$(find "$root" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  [ "$first" = "$second" ]
}

@test "forced-command deploy user can traverse the installed command directory" {
  root="$TEST_ROOT/root"
  mkdir -p "$root"
  run env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$root/opt/mixli/bin")" = '755' ]
  [ "$(stat -c '%a' "$root/opt/mixli/bin/deploy-dispatch")" = '755' ]
}

@test "production firewall covers Docker-published ports through DOCKER-USER" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq 'DOCKER-USER' "$script"
  grep -Fq -- '-i "$interface" -j MIXLI-CLOUDFLARE' "$script"
  grep -Fq -- '--dports 80,443' "$script"
  grep -Fq 'mixli_cloudflare_v4' "$script"
  grep -Fq 'mixli_cloudflare_v6' "$script"
  grep -Fq -- '-j REJECT' "$script"
}

@test "Cloudflare Docker policy does not intercept container egress" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq "ip -4 route show default" "$script"
  grep -Fq "ip -6 route show default" "$script"
  grep -Fq -- '-D DOCKER-USER -j MIXLI-CLOUDFLARE' "$script"
  ! grep -Fq -- '-I DOCKER-USER 1 -j MIXLI-CLOUDFLARE' "$script"
}

@test "host input policy is default deny while preserving key SSH" {
  script="$REPO_ROOT/ops/production/bin/provision-host.sh"
  grep -Fq 'destroy table inet mixli_host_filter' "$script"
  grep -Fq 'table inet mixli_host_filter' "$script"
  grep -Fq 'policy drop' "$script"
  grep -Fq 'tcp dport 22 ct state new accept' "$script"
  grep -Fq 'https://download.docker.com/linux/debian' "$script"
}

@test "runtime helpers share the pinned compose and environment paths" {
  for script in deployment.sh backup.sh; do
    grep -Fq 'runtime/compose.yaml' \
      "$REPO_ROOT/ops/production/bin/$script"
    grep -Fq '/etc/mixli/env/production.env' \
      "$REPO_ROOT/ops/production/bin/$script"
  done
}
