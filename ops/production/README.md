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

- R2:
  1. Create a second Object Read & Write key scoped only to the production backup
     bucket. Keep the old key valid throughout the rotation.
  2. Create a same-directory temporary file as `root:root 0600`, edit it through
     a no-echo channel, and write the complete replacement pgBackRest
     configuration. Do not edit the active file in place.
  3. Validate the candidate's owner and mode with `stat`. Validate, using quiet
     exit-status-only parsing, that the required local, repo2 S3, credential, and
     encryption keys are present in the correct sections and that the fixed repo
     and cipher types are valid. Do not print values. Stop if either validation
     fails.
  4. With the new key, perform a disposable object write, read it back and compare
     locally, then delete it. Use a unique rotation-test object outside pgBackRest
     repository paths and do not put credentials in command-line arguments or
     logs. Stop and leave the active config and old key unchanged on any failure.
  5. Retain one `root:root 0600` rollback copy without displaying it, then
     atomically rename the validated candidate over
     `/etc/mixli/postgres/pgbackrest.conf`. Recheck `root:root 0600` metadata.
  6. During an approved maintenance or deployment window, force-recreate only
     PostgreSQL so its entrypoint stages the new container-private copy, then wait
     for the container to become healthy. A restart is insufficient. If startup
     or health fails, stop the rotation, atomically restore the protected rollback
     file, force-recreate PostgreSQL again, and keep the old key valid.
  7. Run repo1 and repo2 checks, a dual-repository backup, and the isolated repo2
     restore verification. All must succeed with fresh evidence. If any check
     fails, stop, preserve the evidence without secret values, and either repair
     forward or use the protected rollback file and recreate PostgreSQL.
  8. Only after PostgreSQL is healthy and every check, backup, and isolated restore
     succeeds may the old R2 key be revoked. Remove the protected rollback file
     after the revocation and final checks. At no point copy old or new secret
     values into this runbook, shell history, chat, tickets, or logs.
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
