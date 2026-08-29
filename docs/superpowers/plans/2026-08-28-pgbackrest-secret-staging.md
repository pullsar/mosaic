# pgBackRest Root-Only Secret Staging Implementation Plan

> **Required sub-skill:** Use `subagent-driven-development` to execute this plan task by task, with `test-driven-development` for every behavior change and `verification-before-completion` before claiming success.

**Goal:** Keep the production pgBackRest configuration `root:root 0600` on the host while reliably delivering a private `postgres:postgres 0600` runtime copy inside every PostgreSQL or restore container.

**Architecture:** The PostgreSQL image starts as root through a small Mixli wrapper. The wrapper validates the bind-mounted host file at `/run/mixli-secrets/pgbackrest.conf`, copies it atomically to `/etc/pgbackrest/pgbackrest.conf`, validates required keys without printing values, and delegates unchanged to the official PostgreSQL entrypoint. Compose and restore verification mount only the root-only staging path; pgBackRest itself continues to use its normal private runtime path.

**Tech Stack:** Bash, Docker/Compose, PostgreSQL 18.3 official image, pgBackRest, Bats, jq, ShellCheck, systemd-backed server CI.

## Task 1: Lock the staging contract in failing server-side tests

**Files:**

- Create: `ops/production/tests/postgres_entrypoint.bats`
- Modify: `ops/production/tests/compose_config.bats`
- Modify: `ops/production/tests/postgres_backup.bats`

- [ ] Add a Compose assertion that the host pgBackRest file is mounted read-only at `/run/mixli-secrets/pgbackrest.conf`, is never mounted directly at `/etc/pgbackrest/pgbackrest.conf`, and production sets `MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1`.
- [ ] Add wrapper contract tests for missing, empty, non-root-owned, over-permissive, and incomplete staged files. Assert a nonzero exit and invariant-only diagnostics that never contain the test credential marker.
- [ ] Add a success test that records the source file hash and metadata, starts the built image with the source bind-mounted read-only, and proves the private copy is `postgres:postgres 0600` while the source is unchanged.
- [ ] Add a delegation test proving arguments reach the upstream entrypoint and a delegated exit status such as `37` is preserved.
- [ ] Update the existing local backup/restore integration fixture to mount a mode-`0600` local-only config at the staging path; do not add network-backed repo2 credentials to tests.
- [ ] Commit and push only the red tests, then run the targeted server test to prove the current image fails for the intended missing-wrapper/mount reason:

```bash
sudo -u mixli-build git -C /srv/mixli/repository fetch --prune origin ops/production-deployment
sha="$(sudo -u mixli-build git -C /srv/mixli/repository rev-parse origin/ops/production-deployment)"
checkout="/srv/mixli/builds/$sha"
sudo -u mixli-build git -C /srv/mixli/repository worktree add --detach "$checkout" "$sha"
docker build -f "$checkout/ops/production/postgres/Dockerfile" -t mixli-postgres:test "$checkout/ops/production/postgres"
cd "$checkout"
MIXLI_POSTGRES_IMAGE=mixli-postgres:test bats ops/production/tests/postgres_entrypoint.bats ops/production/tests/compose_config.bats
```

## Task 2: Implement the fail-closed PostgreSQL entrypoint

**Files:**

- Create: `ops/production/postgres/docker-entrypoint-mixli.sh`
- Modify: `ops/production/postgres/Dockerfile`

- [ ] Implement a root-only wrapper with `set -Eeuo pipefail` and `umask 077`.
- [ ] Require `/run/mixli-secrets/pgbackrest.conf` to be a nonempty regular file owned by UID/GID `0:0` with exact mode `0600`; reject symlinks and unsafe metadata before copying.
- [ ] Copy to a same-directory temporary file, set `postgres:postgres 0600`, validate it, then atomically rename it to `/etc/pgbackrest/pgbackrest.conf`. Clean temporary files on every failure.
- [ ] Validate `[global]`, `repo1-path`, `[mixli]`, and `pg1-path`. When `MIXLI_PGBACKREST_REQUIRE_REPO2_S3=1`, also require the S3 type, endpoint, bucket, access key, secret key, cipher type, and cipher passphrase keys. Never echo lines or values.
- [ ] Delegate with `exec /usr/local/bin/docker-entrypoint.sh "$@"` so official initialization, privilege dropping, signals, arguments, and exit status remain authoritative.
- [ ] Install `/run/mixli-secrets` as `root:root 0700`, install the wrapper executable, keep the checked-in example under `/usr/local/share/mixli/`, and make the wrapper the image `ENTRYPOINT`.
- [ ] Rebuild the image and rerun `postgres_entrypoint.bats` on the server. The wrapper contract tests must pass; the Compose staging assertion remains RED until Task 3 routes the production mount.

## Task 3: Route production and restore containers through staging

**Files:**

- Modify: `ops/production/compose.yaml`
- Modify: `ops/production/bin/restore-verify.sh`
- Modify: `ops/production/tests/backup_scripts.bats`

- [ ] Change the PostgreSQL bind target from `/etc/pgbackrest/pgbackrest.conf` to `/run/mixli-secrets/pgbackrest.conf`, keep it read-only, and enable strict repo2 validation in production.
- [ ] In isolated restore verification, mount the root-only file at the staging path and let the wrapper run as container root; invoke restore itself as `gosu postgres pgbackrest ...` after staging.
- [ ] Mount the staged file for the temporary restored PostgreSQL boot as well, with archive mode disabled exactly as before.
- [ ] Extend Bats static/runtime assertions so restore verification cannot regress to a direct postgres-readable host mount or a container-wide `--user postgres` override.
- [ ] Run on the server:

```bash
MIXLI_POSTGRES_IMAGE=mixli-postgres:test bats \
  ops/production/tests/postgres_entrypoint.bats \
  ops/production/tests/postgres_backup.bats \
  ops/production/tests/backup_scripts.bats \
  ops/production/tests/compose_config.bats
shellcheck ops/production/postgres/docker-entrypoint-mixli.sh ops/production/bin/restore-verify.sh
```

## Task 4: Document and enforce the operator boundary

**Files:**

- Modify: `ops/production/README.md`
- Modify: `ops/production/tests/provisioning.bats`

- [ ] Document that `/etc/mixli/postgres/pgbackrest.conf` must remain `root:root 0600`, is mounted only at the staging path, and is copied privately on each container start.
- [ ] Document the safe rotation sequence: write and metadata-check a temporary host config, verify the new R2 key with a disposable object, atomically replace the host config, force-recreate PostgreSQL during an approved maintenance/deployment window, then run both repo checks, backup, and isolated restore before revoking the old key.
- [ ] Add a provisioning contract test that the root-only PostgreSQL configuration directory is mode `0750` and that provisioning never creates a credential-bearing runtime config from the public example.
- [ ] Run the documentation/provisioning and shell contract tests on the server.

## Task 5: Full exact-SHA server verification and production activation gate

**Files:**

- Verify only; no new files expected.

- [ ] Push the completed branch and run `/opt/mixli/bin/server-ci.sh` through the existing root-owned CI request path for the exact branch SHA. This is the only full build/test run; do not run application or Flutter tests on the workstation.
- [ ] Require `source-integrity`, `infrastructure-contracts`, API/PostgreSQL integration, Flutter workspace, platform declarations, and production builds to pass in the systemd journal.
- [ ] On the still-disabled production host, verify only metadata and key presence without outputting values:

```bash
sudo stat -c '%U:%G %a %n' /etc/mixli/postgres/pgbackrest.conf
sudo test "$(sudo stat -c '%u:%g:%a' /etc/mixli/postgres/pgbackrest.conf)" = '0:0:600'
```

- [ ] Merge to `main`, deploy the exact merged SHA through `deployment-request.sh`, and require PostgreSQL health plus `pgbackrest --repo=1 check`, `pgbackrest --repo=2 check`, a full dual-repository backup, and the isolated restore service to succeed before enabling recurring timers.
- [ ] If PostgreSQL fails before readiness, inspect only the invariant-level wrapper diagnostic, keep the stack disabled, and do not loosen host permissions as a workaround.
