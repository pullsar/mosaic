# Mixli production operations

This directory is the source of truth for the single-origin production stack at
`mixli.app`. Cloudflare is the public edge; Nginx is the only origin listener;
the application and observability services stay on private Docker networks.
All builds, tests, migrations, and release creation run on the server against an
exact Git SHA. Never copy secret values into GitHub Actions, chat, tickets, or
command-line arguments.

## Fixed paths and identities

| Purpose | Path or identity |
| --- | --- |
| Administrator | `mixli` (key-only SSH, sudo) |
| Restricted trigger | `mixli-deploy` (forced command only) |
| Build owner | `mixli-build` (locked, no login) |
| Git mirror | `/srv/mixli/repository` |
| Immutable checkouts | `/srv/mixli/builds/<sha>` |
| Releases and state | `/srv/mixli/releases`, `/srv/mixli/state` |
| Runtime configuration | `/etc/mixli` and `/srv/mixli/runtime` |
| Installed operators | `/opt/mixli/bin` |
| Deployment/CI events | `/srv/mixli/log/deploy-events.log`, `/srv/mixli/log/ci-events.log` |
| Textfile metrics | `/srv/mixli/metrics` |

Administrator SSH uses the dedicated key and pinned host-key file. From Windows,
the known-compatible invocation is:

```powershell
ssh.exe -i C:\keys\mixli-prod -o IdentitiesOnly=yes -o KexAlgorithms=curve25519-sha256 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=C:\keys\mixli-known-hosts mixli@152.53.55.38
```

## Initial provisioning

1. Install the administrator public key for `mixli`, then run the checked-out
   provisioner as root: `sudo ops/production/bin/provision-host.sh`.
2. Run it a second time. Both runs must exit zero.
3. Verify `sshd -t`, `systemctl is-active docker nftables fail2ban`,
   `docker info`, `nft list table inet mixli_host_filter`, and both
   `iptables -S MIXLI-CLOUDFLARE` and `ip6tables -S MIXLI-CLOUDFLARE`.
4. Open a new administrator SSH session before closing the bootstrap session.
   Prove root/password login is rejected.
5. Install the restricted public key in
   `/var/lib/mixli-deploy/.ssh/authorized_keys` with
   `restrict,command="/opt/mixli/bin/deploy-dispatch"`. An arbitrary command
   must exit 64; `ci <exact-sha>` may only enqueue a server job.
6. Do not enable `mixli-stack.service` until every file below exists and
   Cloudflare DNS, strict TLS, and the origin certificate are ready.

Expected evidence is a default-deny host input chain, Cloudflare-only Docker
80/443 rules, no public database/API port, Docker `live-restore=true`, and a
successful second provisioner run.

## Secret inventory

Create secrets with `sudoedit` or another no-echo channel. Directories are
root-owned mode `0750`; secret/private-key files are root-owned mode `0600`;
the Origin CA certificate may be `0644`. The API database password must be URL
encoded in `DATABASE_URL`.

| File | Required content |
| --- | --- |
| `/etc/mixli/secrets/postgres-password` | One high-entropy PostgreSQL password, no key name |
| `/etc/mixli/secrets/api.env` | `DATABASE_URL=postgresql://mixli:<encoded-password>@postgres:5432/mixli` |
| `/etc/mixli/secrets/postgres-exporter.env` | Read-only exporter `DATA_SOURCE_NAME` |
| `/etc/mixli/secrets/grafana-admin-password` | Independent high-entropy password |
| `/etc/mixli/secrets/alertmanager-webhook-url` | Private notification receiver URL |
| `/etc/mixli/cloudflare/origin.pem` | Origin CA certificate for apex and required subdomains |
| `/etc/mixli/cloudflare/origin.key` | Origin CA private key |
| `/etc/mixli/postgres/pgbackrest.conf` | Runtime copy with bucket-scoped R2 key, secret, endpoint, and an independent repository cipher passphrase |

Check metadata without reading values:

```bash
sudo find /etc/mixli/secrets -maxdepth 1 -type f -printf '%U:%G %m %p\n'
sudo stat -c '%U:%G %a %n' /etc/mixli/cloudflare/origin.pem /etc/mixli/cloudflare/origin.key /etc/mixli/postgres/pgbackrest.conf
```

### pgBackRest root-only operator boundary

Provisioning installs only the non-secret `pgbackrest.conf.example`; it never
creates the live credential-bearing configuration. An operator must create the
live file through a no-echo channel before enabling the production stack.

`/etc/mixli/postgres/pgbackrest.conf` is an operator-managed credential file,
not a container-readable configuration file. It must remain `root:root 0600`.
The production Compose file mounts it read-only only at
`/run/mixli-secrets/pgbackrest.conf`; it must never be mounted directly at the
pgBackRest runtime path. On every PostgreSQL container start, the root entrypoint
validates the staged file, copies it to a same-directory temporary file, changes
that copy to `postgres:postgres 0600`, validates it again, and atomically installs
it as the container-private `/etc/pgbackrest/pgbackrest.conf` before delegating to
PostgreSQL. A host-file update therefore takes effect only after PostgreSQL is
force-recreated.

Do not loosen the host mode, grant a host group read access, or map a numeric
host group such as the container's current `postgres` GID. Container numeric
identities are an implementation detail and are not an authorization boundary.
Permission loosening and numeric host-group mappings are forbidden; the root-only
staging-and-copy flow is the only approved boundary.

Startup fails closed before PostgreSQL runs unless the wrapper itself is root and
the staged source is a non-empty, non-symlink regular file owned by `root:root`
with mode `0600`. It also requires the `global`/`mixli` sections, local repository
and PostgreSQL paths, all production repo2 S3 credential/encryption keys, S3 repo
type, and AES-256-CBC repository encryption. Copy, ownership, mode, content
validation, or atomic-install failure also stops startup; temporary files are
removed. Diagnostics identify only the failed invariant. Never troubleshoot by
printing the file, enabling shell tracing, dumping the environment, or logging
parsed values. Use `stat` for metadata and quiet, exit-status-only checks for
required key names and fixed semantics.

## Cloudflare and Porkbun

Cloudflare must be authoritative for `mixli.app`; Porkbun remains the registrar.
Remove a stale registrar DS record before changing nameservers, then enable
DNSSEC again only with Cloudflare's active DS values. Proxy the apex, `www`,
`api`, and `ops` records to `152.53.55.38`. Use Full (strict), redirect `www` to
the apex, and put `ops.mixli.app` behind Cloudflare Access. The R2 credential is
Object Read & Write for `mixli-production-backups` only. A paid health-check
upgrade requires separate approval.

After delegation, require non-`SERVFAIL` DNSSEC results, an orange-cloud answer,
valid public TLS, a 200 from `/health` and `/ready`, and a 403 or Access login for
an unauthenticated `ops.mixli.app` request.

## CI and deployment

Every branch/PR CI request is only a short SSH enqueue. The server fetches remote
heads and PR refs, validates reachability, and runs `server-ci.sh` inside an
exact detached checkout. Follow it with:

```bash
sudo tail -f /srv/mixli/log/ci-events.log
sudo journalctl -u 'mixli-ci-<first-12-sha>.service' -f
```

A successful event is `ci-passed:<40-character-sha>:<UTC timestamp>`.

For a manual production deployment, deploy only the exact SHA visible on
`origin/main`:

```bash
sudo -u mixli-build git -C /srv/mixli/repository fetch --prune origin main
sha="$(sudo -u mixli-build git -C /srv/mixli/repository rev-parse origin/main)"
sudo /opt/mixli/bin/deployment-request.sh "$sha"
sudo journalctl -u "mixli-deploy-${sha:0:12}.service" -f
```

The GitHub production workflow sends the same `deploy <sha>` forced command and
must finish in seconds; the server unit performs CI, image/web builds, backup,
migrations, candidate health gates, atomic traffic switch, public smoke tests,
and old-pool drain. Success evidence is `deployed:<sha>:<pool>` in
`deploy-events.log`, matching `/srv/mixli/state/current.json`, and both verifier
modes passing.

The deployer atomically pins the exact release's Compose file at
`/srv/mixli/runtime/compose.yaml` and persists both pool image SHAs in the
root-owned environment file. Systemd and scheduled backup jobs use only that
runtime copy, so a reboot cannot drift to an unverified repository checkout.

## Rollback and migration-forward repair

Only roll back when the previous application is compatible with every migration
already applied. Read (do not edit) `current.json` and `previous.json`, confirm
the target remains an ancestor of `origin/main`, then submit it through the same
deployment runner. The runner builds and verifies the exact old SHA and switches
to the inactive pool; it never reverses the database automatically.

If schema compatibility is uncertain or a down migration would discard data,
do not roll back. Create a forward repair on `main`, let server CI pass, and
deploy the repair SHA. A failed post-switch smoke test restores the former web
symlink and upstream pool automatically; evidence remains in
`deploy-events.log`.

## Backups, checks, and restores

Enable schedules only after the first verified dual-repository backup:

```bash
sudo systemctl enable --now mixli-stack.service
sudo systemctl start mixli-backup-full.service
sudo systemctl start mixli-backup-check.service
sudo systemctl enable --now mixli-backup-full.timer mixli-backup-incr.timer mixli-backup-check.timer mixli-restore-verify.timer
sudo systemctl list-timers 'mixli-*'
```

Require `pgbackrest info` to show a valid backup in repo1 and repo2, the check
service to exit zero, and fresh timestamps in
`/srv/mixli/metrics/pgbackrest.prom`. Run the isolated restore service monthly;
it restores only below `/srv/mixli/restore-tests` and must update
`restore-verify.prom` without touching `/srv/mixli/data/postgres`.

For point-in-time recovery, record the UTC target and last known-good SHA. Stop
the stack, preserve the failed data directory read-only, restore repo2 into a
new isolated directory using pgBackRest `--type=time --target='<UTC>'`, start a
temporary PostgreSQL container on a private network, and validate migrations,
sentinel rows, row counts, and application readiness. Promotion is a separate
operator decision: stop all database clients, atomically move the validated
directory into the configured PostgreSQL path, start the stack, deploy the
recorded compatible SHA, and run both verification modes. Never point a restore
container at `/srv/mixli/data/postgres` during validation.

## Rotation

- R2: create a second Object Read & Write key scoped only to the production
  backup bucket. Keep the old key valid. In the candidate configuration, only
  `repo2-s3-key` and `repo2-s3-key-secret` may change. The endpoint, bucket,
  repository path, `repo2-cipher-pass`, and every other setting must remain
  byte-for-byte equivalent.

  Begin an approved maintenance or deployment window in a persistent root shell.
  Acquire the deployment lock before the backup lock, ensure no related unit is
  active, and stop the timers while both locks are held. Keep descriptor 8 and
  therefore the deployment lock through revocation and final verification.

  ```bash
  sudo -i
  set -Eeuo pipefail
  set +x
  umask 077

  compose_file=/srv/mixli/runtime/compose.yaml
  env_file=/etc/mixli/env/production.env
  curl_bin=/usr/bin/curl
  active=/etc/mixli/postgres/pgbackrest.conf
  timer_units='mixli-backup-full.timer mixli-backup-incr.timer mixli-backup-check.timer mixli-restore-verify.timer'
  rotation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  rotation_started_epoch="$(date -u +%s)"
  rotation_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  candidate="/etc/mixli/postgres/.pgbackrest.conf.candidate-$rotation_id"
  rollback="/etc/mixli/postgres/.pgbackrest.conf.rollback-$rotation_id"
  curl_config="/etc/mixli/postgres/.r2-curl-$rotation_id"
  probe_body="/etc/mixli/postgres/.r2-probe-$rotation_id"
  probe_read="/etc/mixli/postgres/.r2-probe-read-$rotation_id"
  probe_object="mixli-rotation-probes/probe-$rotation_id"
  probe_uploaded=0
  timers_stopped=0
  active_replaced=0
  rotation_complete=0

  compose() {
    docker compose --env-file "$env_file" -f "$compose_file" "$@"
  }

  cleanup_rotation() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [[ "$probe_uploaded" == 1 && -f "$curl_config" && -n "${probe_url:-}" ]]; then
      "$curl_bin" --config "$curl_config" --request DELETE --output /dev/null \
        "$probe_url" >/dev/null 2>&1 || true
    fi
    rm -f -- "$candidate" "$curl_config" "$probe_body" "$probe_read"
    if [[ "$status" == 0 && "$rotation_complete" == 1 ]]; then
      rm -f -- "$rollback"
    elif [[ "$status" != 0 && "$active_replaced" == 0 ]]; then
      rm -f -- "$rollback"
      if [[ "$timers_stopped" == 1 ]]; then
        systemctl start $timer_units || true
      fi
    fi
    exit "$status"
  }
  trap cleanup_rotation EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  printf 'R2 rotation started at %s (epoch %s); id=%s\n' \
    "$rotation_started_at" "$rotation_started_epoch" "$rotation_id"

  exec 8>/run/lock/mixli-deploy.lock
  flock -n 8 || exit 75
  exec 9>/run/lock/mixli-backup.lock
  flock -n 9 || exit 75

  active_units="$(systemctl list-units --type=service --state=active \
    --no-legend --plain 'mixli-deploy-*' 'mixli-backup-*.service' \
    'mixli-restore-verify.service')"
  if [[ -n "$active_units" ]]; then
    printf '%s\n' 'R2 rotation stopped: a deployment, backup, or restore unit is active.' >&2
    exit 1
  fi
  unset active_units
  timers_stopped=1
  systemctl stop $timer_units
  ```

  Stop before changing the active file if a lock cannot be acquired, a relevant
  unit is active, or a timer cannot be stopped. Do not reverse the lock order.
  Create unique candidate and rollback files on the same filesystem as the
  active file. Edit only the two key assignments through the no-echo editor.

  ```bash
  if [[ ! -f "$active" || -L "$active" || ! -s "$active" ]]; then
    printf '%s\n' 'R2 rotation stopped: active configuration is not a regular protected file.' >&2
    exit 1
  fi
  test "$(stat -c '%U:%G:%a' "$active")" = 'root:root:600'
  if [[ -e "$candidate" || -L "$candidate" || -e "$rollback" || -L "$rollback" ]]; then
    printf '%s\n' 'R2 rotation stopped: unique candidate or rollback path already exists.' >&2
    exit 1
  fi
  install -o root -g root -m 0600 "$active" "$candidate"
  sudoedit "$candidate"

  if [[ ! -f "$candidate" || -L "$candidate" || ! -s "$candidate" ]]; then
    printf '%s\n' 'R2 rotation stopped: candidate is not a regular protected file.' >&2
    exit 1
  fi
  test "$(stat -c '%U:%G:%a' "$candidate")" = 'root:root:600'

  normalize_rotation_keys() {
    awk '
      /^[[:space:]]*repo2-s3-key[[:space:]]*=/ {
        sub(/=.*/, "=<ROTATED>")
      }
      /^[[:space:]]*repo2-s3-key-secret[[:space:]]*=/ {
        sub(/=.*/, "=<ROTATED>")
      }
      { print }
    ' "$1"
  }

  if cmp -s "$active" "$candidate"; then
    printf '%s\n' 'R2 rotation stopped: candidate does not rotate a key.' >&2
    exit 1
  else
    cmp_status=$?
    if [[ "$cmp_status" -ne 1 ]]; then
      exit "$cmp_status"
    fi
  fi
  cmp -s \
    <(normalize_rotation_keys "$active") \
    <(normalize_rotation_keys "$candidate")

  compose run --rm --no-deps \
    -v "$candidate:/run/mixli-secrets/pgbackrest.conf:ro" \
    postgres true >/dev/null
  ```

  The first quiet `cmp` requires a change; the second normalizes only the two
  permitted key lines and rejects every other textual or semantic change without
  outputting values. The disposable container then applies the production
  entrypoint's value-free section, required-key, fixed-type, ownership, and mode
  checks. Stop if any command fails.

  Exercise the new key with the provisioned, pinned host `curl`. The root-only
  curl configuration keeps credentials out of process arguments and output. The
  unique non-sensitive probe object is outside all pgBackRest repository paths.

  ```bash
  read_global_setting() {
    awk -F= -v wanted="$1" '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[[:space:]]*[#;]/) next
        if (line ~ /^[[:space:]]*\[[^][]]+\][[:space:]]*$/) {
          section = line
          sub(/^[[:space:]]*\[/, "", section)
          sub(/\][[:space:]]*$/, "", section)
          section = trim(section)
          next
        }
        separator = index(line, "=")
        if (section == "global" && separator > 0) {
          key = trim(substr(line, 1, separator - 1))
          if (key == wanted) {
            value = trim(substr(line, separator + 1))
            found++
          }
        }
      }
      END {
        if (found != 1 || value == "") exit 1
        printf "%s", value
      }
    ' "$candidate"
  }

  r2_endpoint="$(read_global_setting repo2-s3-endpoint)"
  r2_bucket="$(read_global_setting repo2-s3-bucket)"
  r2_key="$(read_global_setting repo2-s3-key)"
  r2_secret="$(read_global_setting repo2-s3-key-secret)"
  curl_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
  }
  {
    printf '%s\n' 'silent' 'show-error' 'fail' \
      'aws-sigv4 = "aws:amz:auto:s3"'
    printf 'user = "%s:%s"\n' \
      "$(curl_escape "$r2_key")" "$(curl_escape "$r2_secret")"
  } >"$curl_config"
  unset r2_key r2_secret
  chmod 0600 "$curl_config"
  test "$(stat -c '%U:%G:%a' "$curl_config")" = 'root:root:600'

  probe_url="https://$r2_endpoint/$r2_bucket/$probe_object"
  printf 'mixli-r2-rotation-probe:%s\n' "$rotation_id" >"$probe_body"
  test -x "$curl_bin"
  "$curl_bin" --config "$curl_config" --request PUT --upload-file "$probe_body" \
    --output /dev/null "$probe_url"
  probe_uploaded=1
  "$curl_bin" --config "$curl_config" --output "$probe_read" "$probe_url"
  cmp -s "$probe_body" "$probe_read"
  "$curl_bin" --config "$curl_config" --request DELETE --output /dev/null \
    "$probe_url"
  probe_uploaded=0
  ```

  Stop with the active configuration and old key unchanged if CRUD fails. After
  successful CRUD, create and validate the protected rollback copy, atomically
  replace the active file from the same directory, and force-recreate PostgreSQL
  with the pinned runtime Compose and environment files. A restart is not enough.

  ```bash
  install -o root -g root -m 0600 "$active" "$rollback"
  if [[ ! -f "$rollback" || -L "$rollback" || ! -s "$rollback" ]]; then
    printf '%s\n' 'R2 rotation stopped: rollback copy is not a regular protected file.' >&2
    exit 1
  fi
  test "$(stat -c '%U:%G:%a' "$rollback")" = 'root:root:600'
  active_replaced=1
  if mv -fT -- "$candidate" "$active"; then
    :
  else
    replace_status=$?
    active_replaced=0
    exit "$replace_status"
  fi
  if [[ ! -f "$active" || -L "$active" || ! -s "$active" ]]; then
    printf '%s\n' 'R2 rotation stopped: replacement is not a regular protected file.' >&2
    exit 1
  fi
  test "$(stat -c '%U:%G:%a' "$active")" = 'root:root:600'

  compose up -d --no-deps --force-recreate postgres
  postgres_health=''
  for attempt in $(seq 1 60); do
    postgres_id="$(compose ps -q postgres)"
    if [[ -n "$postgres_id" ]]; then
      postgres_health="$(docker inspect \
        --format '{{.State.Health.Status}}' "$postgres_id" 2>/dev/null || true)"
    fi
    [[ "$postgres_health" == healthy ]] && break
    [[ "$postgres_health" == unhealthy ]] && break
    sleep 2
  done
  test "$postgres_health" = healthy
  docker inspect --format '{{.State.Health.Status}}' "$postgres_id" | \
    grep -Fxq healthy

  compose exec -T --user postgres postgres \
    pgbackrest --stanza=mixli --repo=1 check
  compose exec -T --user postgres postgres \
    pgbackrest --stanza=mixli --repo=2 check
  ```

  The existing backup and restore services acquire the backup lock themselves.
  Release only descriptor 9 before starting them; keep descriptor 8 locked and
  keep all four timers stopped so no scheduled unit can race the ordered checks.

  ```bash
  flock -u 9
  exec 9>&-

  systemctl reset-failed mixli-backup-check.service \
    mixli-backup-incr.service mixli-restore-verify.service
  systemctl start mixli-backup-check.service
  test "$(systemctl show -p Result --value mixli-backup-check.service)" = success
  systemctl start mixli-backup-incr.service
  test "$(systemctl show -p Result --value mixli-backup-incr.service)" = success
  systemctl start mixli-restore-verify.service
  test "$(systemctl show -p Result --value mixli-restore-verify.service)" = success

  check_success="$(awk '$1 == "mixli_pgbackrest_last_check_success_timestamp" {print $2}' \
    /srv/mixli/metrics/pgbackrest.prom | tail -n 1)"
  backup_success="$(awk '$1 == "mixli_pgbackrest_last_backup_success_timestamp" {print $2}' \
    /srv/mixli/metrics/pgbackrest.prom | tail -n 1)"
  restore_success="$(awk '$1 == "mixli_pgbackrest_last_restore_verify_success_timestamp" {print $2}' \
    /srv/mixli/metrics/restore-verify.prom | tail -n 1)"
  [[ "$check_success" =~ ^[0-9]+$ ]]
  [[ "$backup_success" =~ ^[0-9]+$ ]]
  [[ "$restore_success" =~ ^[0-9]+$ ]]
  (( check_success > rotation_started_epoch ))
  (( backup_success > rotation_started_epoch ))
  (( restore_success > rotation_started_epoch ))
  printf 'R2 rotation evidence: start=%s check=%s backup=%s restore=%s\n' \
    "$rotation_started_epoch" "$check_success" "$backup_success" "$restore_success"
  ```

  `mixli-backup-check.service` checks repo1 and repo2,
  `mixli-backup-incr.service` writes a dual-repository backup, and
  `mixli-restore-verify.service` performs the isolated repo2 restore. Revoke the
  old key only after every command and freshness comparison succeeds. With the
  deployment lock still held, run one final new-key check, restart the timers,
  remove the protected rollback copy, and release the deployment lock.

  ```bash
  compose exec -T --user postgres postgres \
    pgbackrest --stanza=mixli --repo=2 check
  if ! systemctl start $timer_units; then
    systemctl stop $timer_units || true
    exit 1
  fi
  timers_stopped=0
  rm -f -- "$rollback"
  rotation_complete=1
  active_replaced=0
  flock -u 8
  exec 8>&-
  exit
  ```

  If any invariant after atomic replacement fails, `errexit` terminates the
  rotation shell. Its exit trap deliberately preserves the rollback file and
  leaves timers stopped; the kernel releases its lock descriptors. Do not revoke
  the old key or continue deployment. Immediately open a new root shell, locate
  the single protected rollback file without reading it, and reacquire the
  deployment lock before the backup lock. Wait for any started backup/restore
  unit to stop, atomically restore the same-directory file, recreate PostgreSQL,
  wait healthy, and check both repositories. Then restart the timers and release
  the locks. These commands never print or copy secret values into documentation,
  shell history, chat, tickets, or logs.

  ```bash
  sudo -i
  set -Eeuo pipefail
  set +x
  umask 077

  compose_file=/srv/mixli/runtime/compose.yaml
  env_file=/etc/mixli/env/production.env
  active=/etc/mixli/postgres/pgbackrest.conf
  timer_units='mixli-backup-full.timer mixli-backup-incr.timer mixli-backup-check.timer mixli-restore-verify.timer'
  compose() {
    docker compose --env-file "$env_file" -f "$compose_file" "$@"
  }

  shopt -s nullglob
  rollback_candidates=(/etc/mixli/postgres/.pgbackrest.conf.rollback-*)
  shopt -u nullglob
  if [[ "${#rollback_candidates[@]}" -ne 1 ]]; then
    printf '%s\n' 'R2 rollback stopped: expected exactly one protected rollback file.' >&2
    exit 1
  fi
  rollback="${rollback_candidates[0]}"

  exec 8>/run/lock/mixli-deploy.lock
  flock -n 8 || exit 75
  exec 9>/run/lock/mixli-backup.lock
  flock -n 9 || exit 75
  systemctl stop $timer_units
  active_units="$(systemctl list-units --type=service --state=active \
    --no-legend --plain 'mixli-backup-*.service' \
    'mixli-restore-verify.service')"
  if [[ -n "$active_units" ]]; then
    printf '%s\n' 'R2 rollback stopped: a backup or restore unit is active.' >&2
    exit 1
  fi
  unset active_units
  if [[ ! -f "$rollback" || -L "$rollback" || ! -s "$rollback" ]]; then
    printf '%s\n' 'R2 rollback stopped: protected rollback copy is unavailable.' >&2
    exit 1
  fi
  test "$(stat -c '%U:%G:%a' "$rollback")" = 'root:root:600'
  if mv -fT -- "$rollback" "$active"; then
    :
  else
    rollback_status=$?
    exit "$rollback_status"
  fi
  compose up -d --no-deps --force-recreate postgres
  postgres_health=''
  for attempt in $(seq 1 60); do
    postgres_id="$(compose ps -q postgres)"
    if [[ -n "$postgres_id" ]]; then
      postgres_health="$(docker inspect \
        --format '{{.State.Health.Status}}' "$postgres_id" 2>/dev/null || true)"
    fi
    [[ "$postgres_health" == healthy ]] && break
    [[ "$postgres_health" == unhealthy ]] && break
    sleep 2
  done
  test "$postgres_health" = healthy
  compose exec -T --user postgres postgres \
    pgbackrest --stanza=mixli --repo=1 check
  compose exec -T --user postgres postgres \
    pgbackrest --stanza=mixli --repo=2 check
  flock -u 9
  exec 9>&-
  if ! systemctl start $timer_units; then
    systemctl stop $timer_units || true
    exit 1
  fi
  flock -u 8
  exec 8>&-
  exit 1
  ```
- Origin certificate: create the replacement, install certificate and key as
  new temporary files, validate key/certificate match and hostname coverage,
  atomically rename them, run `nginx -t`, and gracefully reload Nginx. Revoke
  the old certificate after public strict-TLS verification.
- Administrator key: append the new public key, prove a new independent session
  and sudo, then remove the old key. Never remove the only proven recovery key.
- GitHub deploy key: append the new forced-command public key, update the GitHub
  environment secret, prove `ci <sha>` and rejection of arbitrary commands,
  then remove the old key.

## Total-host rebuild

Provision a clean Debian host, validate its host key out of band, install the
administrator key, run this repository's provisioner twice, and restore the
root-owned secret/config bundle through a secure channel. Validate R2 access,
restore PostgreSQL into isolation, promote the verified data, deploy the
recorded exact SHA, and run origin verification. Only then update Cloudflare
origin DNS, refresh the Cloudflare IP allowlist, and run public verification.
Keep the old origin isolated until rollback is no longer required.

## Incident triage

1. Preserve availability: check Cloudflare status, public `/health`, origin
   `/nginx-health`, `systemctl --failed`, and `docker compose ps`.
2. Identify scope: Nginx, one API replica/pool, PostgreSQL, host capacity,
   certificate, DNSSEC, R2, or external monitoring.
3. Inspect `journalctl -u mixli-stack.service`, container logs with bounded
   `--since`/`--tail`, deployment and CI events, Prometheus alerts, disk/inode
   use, OOM events, and PostgreSQL/pgBackRest status. Never dump environments.
4. Prefer a compatible pool rollback for application-only regressions; prefer a
   forward repair for migrated schemas; use the recovery procedure for data
   loss. Do not bypass the Cloudflare-only origin firewall as an automatic fix.
5. After stabilization, run:

```bash
sudo /opt/mixli/bin/verify-production.sh --origin
sudo /opt/mixli/bin/verify-production.sh --public
sudo systemctl --failed
sudo systemctl list-timers 'mixli-*'
```

All checks must pass, current state must match the API release identity, backup
and WAL evidence must be fresh, and no unexpected public listener may remain.
