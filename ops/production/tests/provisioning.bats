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
  [ "$(stat -c '%u:%g:%a' "$root/etc/mixli/prometheus")" = '65534:65534:750' ]
  [ "$(stat -c '%u:%g:%a' "$root/etc/mixli/prometheus/prometheus.yml")" = \
    '65534:65534:640' ]
  run sudo -u nobody test -r "$root/etc/mixli/prometheus/prometheus.yml"
  [ "$status" -eq 0 ]
}

@test "reprovisioning preserves the generated Cloudflare real-IP trust file" {
  root="$TEST_ROOT/root"
  mkdir -p "$root"
  env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  printf '%s\n' 'set_real_ip_from 203.0.113.0/24;' \
    >"$root/etc/mixli/nginx/cloudflare-real-ip.conf"

  run env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"

  [ "$status" -eq 0 ]
  [ "$(cat "$root/etc/mixli/nginx/cloudflare-real-ip.conf")" = \
    'set_real_ip_from 203.0.113.0/24;' ]
}

@test "provisioning repairs postgres config ownership and installs only the public example" {
  root="$TEST_ROOT/root"
  mkdir -p "$root"

  sudo env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  sudo chown 12345:12345 "$root/etc/mixli/postgres"
  sudo chmod 0777 "$root/etc/mixli/postgres"

  run sudo env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
  provision_status="$status"

  postgres_metadata="$(sudo stat -c '%U:%G:%a' "$root/etc/mixli/postgres")"
  example_metadata="$(sudo stat -c '%U:%G:%a' \
    "$root/etc/mixli/postgres/pgbackrest.conf.example")"
  if sudo cmp -s "$REPO_ROOT/ops/production/postgres/pgbackrest.conf.example" \
    "$root/etc/mixli/postgres/pgbackrest.conf.example"; then
    example_matches=1
  else
    example_matches=0
  fi
  if sudo test -e "$root/etc/mixli/postgres/pgbackrest.conf" || \
    sudo test -L "$root/etc/mixli/postgres/pgbackrest.conf"; then
    live_config_present=1
  else
    live_config_present=0
  fi
  pgbackrest_entries="$(sudo find "$root/etc/mixli/postgres" -maxdepth 1 \
    -name 'pgbackrest.conf*' -printf '%f %y\n' | sort)"

  sudo chown -R "$(id -u):$(id -g)" "$root"

  [ "$provision_status" -eq 0 ]
  [ "$postgres_metadata" = 'root:root:750' ]
  [ "$example_metadata" = 'root:root:640' ]
  [ "$example_matches" -eq 1 ]
  [ "$live_config_present" -eq 0 ]
  [ "$pgbackrest_entries" = 'pgbackrest.conf.example f' ]
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

@test "production firewall covers Docker-published ports in an nft forward hook" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq 'hook forward priority -10' "$script"
  grep -Fq 'tcp dport { 80, 443 }' "$script"
  grep -Fq 'cloudflare_v4' "$script"
  grep -Fq 'cloudflare_v6' "$script"
  grep -Fq 'reject' "$script"
}

@test "Cloudflare Docker policy does not intercept container egress" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq "ip -4 route show default" "$script"
  grep -Fq "ip -6 route show default" "$script"
  grep -Fq 'iifname \"$interface_v4\"' "$script"
  grep -Fq 'iifname \"$interface_v6\"' "$script"
  ! grep -Fq 'hook output' "$script"
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

@test "R2 rotation keeps failures reboot-safe and unlocks before timer restoration" {
  readme="$REPO_ROOT/ops/production/README.md"
  cleanup="$(sed -n '/^  cleanup_rotation()/,/^  }/p' "$readme")"

  grep -Fq 'systemctl is-enabled --quiet "$timer"' "$readme"
  grep -Fq 'systemctl is-active --quiet "$timer"' "$readme"
  grep -Fq 'systemctl disable --now $timer_units' "$readme"
  grep -Fq 'systemctl enable --now $timer_units' "$readme"
  grep -Fq 'timers_expected_enabled_active=1' "$readme"

  unlock_line="$(grep -n 'release_backup_lock' <<<"$cleanup" | tail -n 1 | cut -d: -f1)"
  enable_line="$(grep -n 'systemctl enable --now' <<<"$cleanup" | cut -d: -f1)"
  [ -n "$unlock_line" ]
  [ -n "$enable_line" ]
  [ "$unlock_line" -lt "$enable_line" ]

  [[ "$cleanup" == *'"$active_replaced" == 0'* ]]
}
