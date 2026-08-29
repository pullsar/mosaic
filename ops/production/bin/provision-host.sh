#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly TEST_MODE="${MIXLI_PROVISION_TEST_MODE:-0}"
readonly TARGET_ROOT="${MIXLI_PROVISION_ROOT:-/}"
readonly SOURCE_ROOT="${MIXLI_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
readonly REPOSITORY_URL='https://github.com/pullsar/mosaic.git'

target() {
  local path="$1"
  if [[ "$TARGET_ROOT" == '/' ]]; then
    printf '%s' "$path"
  else
    printf '%s%s' "$TARGET_ROOT" "$path"
  fi
}

install_layout() {
  local path real_ip_config
  install -d -m 0755 "$(target /srv/mixli)"
  for path in \
    /srv/mixli/builds /srv/mixli/releases /srv/mixli/runtime \
    /srv/mixli/state /srv/mixli/log /srv/mixli/metrics /srv/mixli/data/postgres \
    /srv/mixli/data/monitoring/prometheus /srv/mixli/data/monitoring/alertmanager \
    /srv/mixli/data/monitoring/grafana /srv/mixli/backups/pgbackrest \
    /etc/mixli/env /etc/mixli/secrets /etc/mixli/postgres \
    /etc/mixli/nginx/conf.d /etc/mixli/cloudflare /etc/mixli/prometheus \
    /etc/mixli/alertmanager /etc/mixli/grafana/provisioning /etc/mixli/grafana/dashboards \
    /etc/systemd/system; do
    install -d -m 0750 "$(target "$path")"
  done
  install -d -m 0755 "$(target /srv/mixli/releases)"
  install -d -m 0750 "$(target /etc/mixli/secrets)"
  install -d -o root -g root -m 0750 "$(target /etc/mixli/github)"
  install -d -o root -g root -m 0750 "$(target /srv/mixli/state/reviews)"
  install -d -o 65534 -g 65534 -m 0750 "$(target /srv/mixli/metrics)"
  install -d -o root -g 65534 -m 0750 "$(target /etc/mixli/prometheus)"

  # Reassert the credential-directory boundary even when the directory already
  # exists with unsafe ownership or permissions.
  install -d -o root -g root -m 0750 "$(target /etc/mixli/postgres)"

  # The restricted SSH account must be able to execute deploy-dispatch. The
  # directory is traversable, while every command remains root-owned and
  # non-writable by that account.
  install -d -m 0755 "$(target /opt/mixli/bin)"
  install -m 0755 "$SOURCE_ROOT"/ops/production/bin/* "$(target /opt/mixli/bin/)"
  install -m 0644 "$SOURCE_ROOT/ops/production/postgres/postgresql.conf" \
    "$(target /etc/mixli/postgres/postgresql.conf)"
  install -m 0640 "$SOURCE_ROOT/ops/production/postgres/pgbackrest.conf.example" \
    "$(target /etc/mixli/postgres/pgbackrest.conf.example)"
  install -m 0644 "$SOURCE_ROOT/ops/production/nginx/nginx.conf" \
    "$(target /etc/mixli/nginx/nginx.conf)"
  install -m 0644 "$SOURCE_ROOT/ops/production/nginx/conf.d/mixli.conf" \
    "$(target /etc/mixli/nginx/conf.d/mixli.conf)"
  real_ip_config="$(target /etc/mixli/nginx/cloudflare-real-ip.conf)"
  [[ ! -L "$real_ip_config" ]]
  if [[ ! -e "$real_ip_config" ]]; then
    install -m 0644 "$SOURCE_ROOT/ops/production/nginx/cloudflare-real-ip.conf.example" \
      "$real_ip_config"
  fi
  install -o root -g 65534 -m 0640 "$SOURCE_ROOT"/ops/production/prometheus/* \
    "$(target /etc/mixli/prometheus/)"
  install -m 0644 "$SOURCE_ROOT/ops/production/alertmanager/alertmanager.yml" \
    "$(target /etc/mixli/alertmanager/alertmanager.yml)"
  cp -a --no-preserve=ownership "$SOURCE_ROOT/ops/production/grafana/provisioning/." \
    "$(target /etc/mixli/grafana/provisioning/)"
  install -m 0644 \
    "$SOURCE_ROOT/ops/production/grafana/provisioning/dashboards/mixli-overview.json" \
    "$(target /etc/mixli/grafana/dashboards/mixli-overview.json)"
  install -m 0644 "$SOURCE_ROOT"/ops/production/systemd/* \
    "$(target /etc/systemd/system/)"

  if [[ ! -e "$(target /etc/mixli/env/production.env)" ]]; then
    install -m 0600 "$SOURCE_ROOT/ops/production/env/production.env.example" \
      "$(target /etc/mixli/env/production.env)"
  fi
  if [[ ! -e "$(target /srv/mixli/runtime/api-upstream.conf)" ]]; then
    install -m 0644 "$SOURCE_ROOT/ops/production/runtime/api-upstream.example.conf" \
      "$(target /srv/mixli/runtime/api-upstream.conf)"
  fi
}

install_packages() {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl git jq openssh-server sudo fail2ban unattended-upgrades \
    nftables shellcheck bats python3-yaml uidmap slirp4netns

  if ! command -v docker >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --location \
      https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    # Distribution metadata is supplied by Debian.
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://download.docker.com/linux/debian' \
      "Suites: $VERSION_CODENAME" \
      'Components: stable' \
      'Architectures: amd64' \
      'Signed-By: /etc/apt/keyrings/docker.asc' \
      >/etc/apt/sources.list.d/docker.sources
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      docker-ce-rootless-extras
  elif ! dpkg-query -W docker-ce-rootless-extras >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce-rootless-extras
  fi
}

ensure_subordinate_ids() {
  local file="$1" option="$2" start end
  grep -Eq '^mixli-build:[0-9]+:65536$' "$file" && return 0
  start="$(awk -F: '
    BEGIN { maximum = 99999 }
    NF == 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      candidate = $2 + $3 - 1
      if (candidate > maximum) maximum = candidate
    }
    END { print maximum + 1 }
  ' "$file")"
  end=$((start + 65535))
  usermod "$option" "$start-$end" mixli-build
}

ensure_account() {
  local name="$1" home="$2" shell="$3"
  if ! id "$name" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$home" --shell "$shell" --user-group "$name"
  fi
  passwd -l "$name" >/dev/null
}

configure_host() {
  ensure_account mixli-build /srv/mixli /usr/sbin/nologin
  ensure_account mixli-deploy /var/lib/mixli-deploy /bin/bash
  ensure_account mixli-review /var/lib/mixli-review /bin/bash
  ensure_subordinate_ids /etc/subuid --add-subuids
  ensure_subordinate_ids /etc/subgid --add-subgids
  runuser -u mixli-build -- env HOME=/srv/mixli dockerd-rootless-setuptool.sh check
  install_layout
  install -d -o mixli-build -g mixli-build -m 0750 /srv/mixli/repository
  chown -R mixli-build:mixli-build /srv/mixli/builds /srv/mixli/repository
  chown -R 999:999 /srv/mixli/data/postgres /srv/mixli/backups/pgbackrest
  chown -R 65534:65534 /srv/mixli/data/monitoring/prometheus \
    /srv/mixli/data/monitoring/alertmanager
  chown -R 472:472 /srv/mixli/data/monitoring/grafana

  if [[ ! -d /srv/mixli/repository/.git ]]; then
    runuser -u mixli-build -- git clone --no-checkout "$REPOSITORY_URL" /srv/mixli/repository
  fi
  [[ "$(runuser -u mixli-build -- git -C /srv/mixli/repository remote get-url origin)" == "$REPOSITORY_URL" ]]

  printf '%s\n' \
    'destroy table inet mixli_host_filter' \
    'table inet mixli_host_filter {' \
    '  chain input {' \
    '    type filter hook input priority filter; policy drop;' \
    '    ct state established,related accept' \
    '    iifname "lo" accept' \
    '    ip protocol icmp accept' \
    '    ip6 nexthdr ipv6-icmp accept' \
    '    tcp dport 22 ct state new accept' \
    '  }' \
    '  chain forward { type filter hook forward priority filter; policy accept; }' \
    '  chain output { type filter hook output priority filter; policy accept; }' \
    '}' >/etc/nftables.conf

  printf '%s\n' \
    '[sshd]' \
    'enabled = true' \
    'backend = systemd' \
    'maxretry = 5' \
    'findtime = 10m' \
    'bantime = 1h' >/etc/fail2ban/jail.d/mixli-sshd.conf

  printf '%s\n' \
    '{' \
    '  "log-driver": "local",' \
    '  "log-opts": {"max-size": "20m", "max-file": "5"},' \
    '  "live-restore": true' \
    '}' >/etc/docker/daemon.json

  printf '%s\n' \
    'mixli-deploy ALL=(root) NOPASSWD: /opt/mixli/bin/deployment-request.sh *, /opt/mixli/bin/ci-request.sh *' \
    >/etc/sudoers.d/91-mixli-deploy
  chmod 0440 /etc/sudoers.d/91-mixli-deploy
  visudo -cf /etc/sudoers.d/91-mixli-deploy

  printf '%s\n' \
    'mixli-review ALL=(root) NOPASSWD: /opt/mixli/bin/review-request.sh *' \
    >/etc/sudoers.d/92-mixli-review
  chmod 0440 /etc/sudoers.d/92-mixli-review
  visudo -cf /etc/sudoers.d/92-mixli-review

  nft -f /etc/nftables.conf
  systemctl enable --now nftables fail2ban unattended-upgrades docker
  systemctl reload docker || systemctl restart docker
  systemctl daemon-reload
  systemctl enable --now mixli-cloudflare-ips.timer
}

main() {
  [[ "$TARGET_ROOT" == /* && "$TARGET_ROOT" != '' ]]
  if [[ "$TEST_MODE" == '1' ]]; then
    [[ "$TARGET_ROOT" != '/' ]]
    install_layout
    return 0
  fi
  [[ "$EUID" -eq 0 && "$TARGET_ROOT" == '/' ]]
  install_packages
  configure_host
}

main
