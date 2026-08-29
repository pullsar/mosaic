#!/usr/bin/env bats

load test_helper

setup() { setup_repo_root; }

@test "production SSH CI is push-main only" {
  workflow="$REPO_ROOT/.github/workflows/server-ci.yml"
  grep -Fq 'branches: [main]' "$workflow"
  ! grep -Eq 'workflow_dispatch:|branches-ignore:|pull_request:' "$workflow"
}

@test "server CI requests accept only protected main ancestry" {
  script="$REPO_ROOT/ops/production/bin/ci-request.sh"
  grep -Fq 'fetch --prune origin main' "$script"
  grep -Fq 'merge-base --is-ancestor "$SHA" origin/main' "$script"
  ! grep -Fq '+refs/heads/*' "$script"
  ! grep -Fq '+refs/pull/*' "$script"
}

@test "checkout-controlled host validators run as the locked build account" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  runner="$(sed -n '/^builder_exec()/,/^}/p' "$script")"
  [[ "$runner" == *'runuser -u mixli-build --'* ]]
  for command in bats shellcheck systemd-analyze find grep; do
    grep -Eq "builder_exec .*${command}|builder_exec[[:space:]]+${command}" "$script"
  done
  ! grep -Eq 'usermod.*mixli-build.*docker|mixli-build.*NOPASSWD' \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"
}

@test "build account has no production Docker secret or data authority" {
  if [[ "$(id -u)" -eq 0 ]]; then
    prefix=(runuser -u mixli-build --)
  else
    prefix=()
    [ "$(id -un)" = 'mixli-build' ]
  fi
  run "${prefix[@]}" /usr/bin/docker info
  [ "$status" -ne 0 ]
  run "${prefix[@]}" test -r /etc/mixli/secrets
  [ "$status" -ne 0 ]
  run "${prefix[@]}" test -w /srv/mixli/data
  [ "$status" -ne 0 ]
  ! id -nG mixli-build | grep -Eq '(^|[[:space:]])(docker|sudo)([[:space:]]|$)'
}

@test "release web is nginx-readable without broadening secrets" {
  deploy="$REPO_ROOT/ops/production/bin/deployment.sh"
  provision="$REPO_ROOT/ops/production/bin/provision-host.sh"
  grep -Fq 'install -d -m 0755 "$release_dir" "$release_dir/web"' "$deploy"
  grep -Fq 'chmod -R a=rX,u+w "$release_dir/web"' "$deploy"
  grep -Fq 'install -d -m 0755 "$(target /srv/mixli)"' "$provision"
  grep -Fq 'install -d -m 0755 "$(target /srv/mixli/releases)"' "$provision"
  grep -Fq 'install -d -m 0750 "$(target /etc/mixli/secrets)"' "$provision"
}

@test "atomic Nginx inputs use stable parent-directory mounts" {
  compose="$REPO_ROOT/ops/production/compose.yaml"
  grep -Fq 'source: ${MIXLI_NGINX_CONFIG_DIR:-/etc/mixli/nginx}' "$compose"
  grep -Fq 'target: /etc/nginx/mixli' "$compose"
  grep -Fq 'source: ${MIXLI_RELEASE_ROOT:-/srv/mixli}/runtime' "$compose"
  grep -Fq 'target: /etc/nginx/runtime' "$compose"
  grep -Fq 'source: ${MIXLI_CLOUDFLARE_CONFIG_DIR:-/etc/mixli/cloudflare}' "$compose"
  grep -Fq 'target: /etc/nginx/tls' "$compose"
  ! grep -Fq 'source: ${MIXLI_ORIGIN_CERT' "$compose"
}

@test "deployment origin smoke uses explicit local trust and SNI" {
  smoke="$(sed -n '/^smoke_release()/,/^}/p' "$REPO_ROOT/ops/production/bin/deployment.sh")"
  [[ "$smoke" == *'--cacert "$ORIGIN_CA"'* ]]
  [[ "$smoke" == *'--resolve api.mixli.app:443:127.0.0.1'* ]]
  [[ "$smoke" == *'--resolve mixli.app:443:127.0.0.1'* ]]
  [[ "$smoke" != *'--insecure'* ]]
}

@test "monitoring secrets are staged with identity-specific modes" {
  stage="$REPO_ROOT/ops/production/bin/stage-container-secrets.sh"
  [ -f "$stage" ]
  grep -Fq 'install -o 65534 -g 65534 -m 0400' "$stage"
  grep -Fq 'install -o 472 -g 472 -m 0400' "$stage"
  ! grep -Eq 'chmod[[:space:]]+0?644|install .* -m 0?644' "$stage"
  grep -Fq 'ExecStartPre=/opt/mixli/bin/stage-container-secrets.sh' \
    "$REPO_ROOT/ops/production/systemd/mixli-stack.service"
  grep -Fq '/run/mixli/container-secrets/alertmanager-webhook-url' \
    "$REPO_ROOT/ops/production/compose.yaml"
  grep -Fq '/run/mixli/container-secrets/grafana-admin-password' \
    "$REPO_ROOT/ops/production/compose.yaml"
}

@test "Cloudflare refresh is an atomic persistent nft transaction" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq 'nft -c -f "$candidate"' "$script"
  grep -Fq 'nft -f "$candidate"' "$script"
  grep -Fq 'LAST_KNOWN_GOOD' "$script"
  grep -Fq 'hook forward priority -10' "$script"
  grep -Fq 'tcp dport { 80, 443 } reject' "$script"
  ! grep -Eq 'iptables|ip6tables|ipset| -F ' "$script"
}

@test "Cloudflare refresh discovers both ingress families and rolls back both planes" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq 'ip -4 route show default' "$script"
  grep -Fq 'ip -6 route show default' "$script"
  grep -Fq 'render_nft "$v4" "$v6" "$interface_v4" "$interface_v6"' "$script"
  grep -Fq 'rollback_real_ip' "$script"
  grep -Fq 'nft -f "$LAST_KNOWN_GOOD"' "$script"
}

@test "stack cannot start before fail-closed firewall activation" {
  stack="$REPO_ROOT/ops/production/systemd/mixli-stack.service"
  firewall="$REPO_ROOT/ops/production/systemd/mixli-cloudflare-ips.service"
  timer="$REPO_ROOT/ops/production/systemd/mixli-cloudflare-ips.timer"
  grep -Eq '^Requires=.*mixli-cloudflare-ips.service' "$stack"
  grep -Eq '^After=.*mixli-cloudflare-ips.service' "$stack"
  grep -Fq 'Before=mixli-stack.service' "$firewall"
  grep -Eq '^OnBootSec=(0|[0-9]+s)$' "$timer"
  ! grep -Fq 'RandomizedDelaySec' "$timer"
}

@test "Cloudflare real-IP trust validates before atomic replace and reload" {
  script="$REPO_ROOT/ops/production/bin/update-cloudflare-ips.sh"
  grep -Fq 'set_real_ip_from' "$script"
  grep -Fq 'real_ip_header CF-Connecting-IP' "$script"
  validate_line="$(grep -n 'nginx -t' "$script" | head -n1 | cut -d: -f1)"
  replace_line="$(grep -n 'mv -fT.*cloudflare-real-ip.conf' "$script" | head -n1 | cut -d: -f1)"
  reload_line="$(grep -n 'nginx -s reload' "$script" | head -n1 | cut -d: -f1)"
  [ -n "$validate_line" ] && [ -n "$replace_line" ] && [ -n "$reload_line" ]
  [ "$validate_line" -lt "$replace_line" ]
  [ "$replace_line" -lt "$reload_line" ]
}

@test "textfile metrics are least-privilege readable and absence alerts" {
  for script in backup.sh restore-verify.sh; do
    grep -Fq 'install -d -o 65534 -g 65534 -m 0750 "$METRICS_DIR"' \
      "$REPO_ROOT/ops/production/bin/$script"
    grep -Fq 'install -o 65534 -g 65534 -m 0640' \
      "$REPO_ROOT/ops/production/bin/$script"
  done
  rules="$REPO_ROOT/ops/production/prometheus/rules.yml"
  grep -Fq 'absent(mixli_pgbackrest_last_backup_success_timestamp)' "$rules"
  grep -Fq 'absent(mixli_pgbackrest_last_restore_verify_success_timestamp)' "$rules"
}
