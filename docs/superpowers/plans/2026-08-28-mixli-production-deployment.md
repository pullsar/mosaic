# Mixli Production Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the exact approved Mosaic commit to `mixli.app` and `api.mixli.app` through a hardened, Cloudflare-proxied, blue/green production stack with tested PostgreSQL recovery.

**Architecture:** Cloudflare proxies the public hostnames to an Nginx origin. Nginx serves an atomic Flutter web release and an active two-replica Fastify pool; Docker Compose runs blue and green API pools, PostgreSQL 18, pgBackRest, and private observability services. A root-owned `deployment.sh` performs build/test/migrate/switch/rollback work on the server and can be invoked manually or through a forced-command GitHub deployment key.

**Tech Stack:** Debian 13, Docker Engine/Compose, Nginx, Node.js 24, Fastify 5, Flutter 3.44.7/Dart 3.12.2, PostgreSQL 18.3, pgBackRest, Cloudflare DNS/Origin CA/R2/Access, Prometheus, Grafana, Alertmanager, Bash, GitHub Actions.

---

## File map

- `.github/workflows/deploy-production.yml`: short GitHub-hosted deployment trigger.
- `.gitignore`: production secret/runtime exclusions.
- `apps/api/Dockerfile`: immutable Node 24 API/migration image.
- `apps/api/src/metrics.ts`: private Prometheus registry and request instrumentation.
- `apps/api/test/metrics.test.ts`: metrics exposure and label-cardinality tests.
- `ops/production/compose.yaml`: production services, networks, health checks, and limits.
- `ops/production/env/production.env.example`: non-secret runtime contract.
- `ops/production/flutter/Dockerfile`: pinned Flutter 3.44.7 build/test environment.
- `ops/production/postgres/Dockerfile`: PostgreSQL 18.3 plus pgBackRest.
- `ops/production/postgres/postgresql.conf`: conservative initial database settings and WAL archive hook.
- `ops/production/postgres/pgbackrest.conf.example`: local and R2 repository contract without credentials.
- `ops/production/nginx/nginx.conf`: global Nginx behavior, logging, real-IP trust, and WebSocket map.
- `ops/production/nginx/conf.d/mixli.conf`: web/API/ops virtual hosts and cache behavior.
- `ops/production/nginx/runtime/api-upstream.example.conf`: initial active-pool include format.
- `ops/production/prometheus/prometheus.yml`: scrape configuration.
- `ops/production/prometheus/rules.yml`: availability, capacity, database, and backup alerts.
- `ops/production/alertmanager/alertmanager.yml`: local alert receiver and external webhook contract.
- `ops/production/grafana/provisioning/datasources/prometheus.yml`: automatic datasource.
- `ops/production/grafana/provisioning/dashboards/mixli-overview.json`: baseline service/database/backup dashboard.
- `ops/production/bin/deployment.sh`: exact-SHA server-side CI and blue/green deployment runner.
- `ops/production/bin/deploy-dispatch`: forced SSH command parser.
- `ops/production/bin/backup.sh`: full/incremental/check backup entrypoint.
- `ops/production/bin/restore-verify.sh`: isolated R2 restore drill.
- `ops/production/bin/update-cloudflare-ips.sh`: validated Cloudflare origin allowlist refresh.
- `ops/production/bin/verify-production.sh`: repeatable host/public acceptance checks.
- `ops/production/bin/provision-host.sh`: idempotent packages, directories, accounts, Docker, firewall, and service bootstrap.
- `ops/production/systemd/*.service` and `*.timer`: stack, backup, restore-drill, and IP-refresh scheduling.
- `ops/production/tests/*.bats`: shell-level deployment, dispatch, rollback, and firewall tests.
- `ops/production/README.md`: manual deployment, rollback, restore, secret rotation, and incident procedures.

### Task 1: Protect secrets and establish the shell test harness

**Files:**
- Modify: `.gitignore`
- Create: `ops/production/tests/test_helper.bash`
- Create: `ops/production/tests/deploy_dispatch.bats`

- [ ] **Step 1: Write the failing forced-command tests**

Create tests that set `SSH_ORIGINAL_COMMAND` and execute an overrideable dispatcher in test mode. Cover exactly these cases:

```bash
@test "accepts deploy followed by a 40-character lowercase SHA" {
  SSH_ORIGINAL_COMMAND="deploy b5098ec72c804b6df97a7017681ea17b9843d73c" \
    MIXLI_DEPLOY_TEST_MODE=1 run "$REPO_ROOT/ops/production/bin/deploy-dispatch"
  [ "$status" -eq 0 ]
  [ "$output" = "b5098ec72c804b6df97a7017681ea17b9843d73c" ]
}

@test "rejects shell metacharacters" {
  SSH_ORIGINAL_COMMAND="deploy b5098ec72c804b6df97a7017681ea17b9843d73c;id" \
    MIXLI_DEPLOY_TEST_MODE=1 run "$REPO_ROOT/ops/production/bin/deploy-dispatch"
  [ "$status" -ne 0 ]
}

@test "rejects an interactive shell" {
  SSH_ORIGINAL_COMMAND="" MIXLI_DEPLOY_TEST_MODE=1 \
    run "$REPO_ROOT/ops/production/bin/deploy-dispatch"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests and verify the missing dispatcher fails**

Run: `docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/deploy_dispatch.bats`

Expected: non-zero status because `ops/production/bin/deploy-dispatch` does not exist.

- [ ] **Step 3: Add production runtime exclusions**

Append these exact patterns to `.gitignore`:

```gitignore
ops/production/env/production.env
ops/production/secrets/
ops/production/runtime/
ops/production/images.lock.env
```

- [ ] **Step 4: Create the strict dispatcher**

Create `ops/production/bin/deploy-dispatch` with `set -Eeuo pipefail`, a regex requiring `deploy [0-9a-f]{40}`, test-mode SHA output, and production execution of:

```bash
exec sudo -n /opt/mixli/bin/deployment.sh "$sha"
```

Reject every other command with exit 64.

- [ ] **Step 5: Run the tests and ShellCheck**

Run:

```bash
docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/deploy_dispatch.bats
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 ops/production/bin/deploy-dispatch
```

Expected: all Bats tests pass and ShellCheck exits 0.

- [ ] **Step 6: Commit**

```bash
git add .gitignore ops/production/tests ops/production/bin/deploy-dispatch
git commit -m "ops: add restricted deployment dispatcher"
```

### Task 2: Build a minimal production API image

**Files:**
- Create: `apps/api/Dockerfile`
- Create: `.dockerignore`
- Create: `ops/production/tests/api_image.bats`

- [ ] **Step 1: Write failing image-contract tests**

Test that a built image runs as a non-root UID, contains `dist/server.js`, contains `dist/db/migrate.js` and `migrations/`, has Node major version 24, and has no `tsx` executable in production `node_modules/.bin`.

- [ ] **Step 2: Verify the tests fail before the Dockerfile exists**

Run: `docker build -f apps/api/Dockerfile -t mixli-api:test .`

Expected: non-zero status because the Dockerfile is missing.

- [ ] **Step 3: Create the multi-stage image**

Use `node:24.7.0-bookworm-slim` for both stages. The build stage copies `apps/api/package*.json`, runs `npm ci --ignore-scripts`, copies `apps/api/src`, `migrations`, and TypeScript configs, then runs `npm run typecheck`, `npm test`, and `npm run build`. The runtime stage copies the package manifests and production dependencies after `npm prune --omit=dev --ignore-scripts`, `dist/`, and `migrations/`. Set:

```dockerfile
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080
USER node
EXPOSE 8080
CMD ["node", "--enable-source-maps", "dist/server.js"]
```

Add a Node-based `HEALTHCHECK` against `http://127.0.0.1:8080/ready` so curl is not added to the runtime image.

- [ ] **Step 4: Add a root `.dockerignore`**

Exclude `.git`, local build outputs, IDE files, production secrets/runtime state, and `mixli-brand-kit-v2/`. Do not exclude API migrations, Dart packages, contracts, or lockfiles.

- [ ] **Step 5: Build and run image-contract tests**

Run:

```bash
docker build -f apps/api/Dockerfile -t mixli-api:test .
docker run --rm --entrypoint sh mixli-api:test -c 'test "$(id -u)" -ne 0 && test -f dist/server.js && test -f dist/db/migrate.js && test -d migrations && test ! -x node_modules/.bin/tsx && node --version | grep -q "^v24\."'
```

Expected: build and contract checks exit 0.

- [ ] **Step 6: Commit**

```bash
git add .dockerignore apps/api/Dockerfile ops/production/tests/api_image.bats
git commit -m "ops: add production API image"
```

### Task 3: Create the pinned Flutter build environment

**Files:**
- Create: `ops/production/flutter/Dockerfile`
- Create: `ops/production/tests/flutter_image.bats`

- [ ] **Step 1: Write the failing Flutter version test**

The test builds `mixli-flutter-builder:test` and asserts that `flutter --version --machine` reports Flutter `3.44.7` and Dart `3.12.2`.

- [ ] **Step 2: Verify it fails before implementation**

Run: `docker build -f ops/production/flutter/Dockerfile -t mixli-flutter-builder:test ops/production/flutter`

Expected: non-zero status because the Dockerfile is missing.

- [ ] **Step 3: Create the builder image**

Base the image on `debian:13.1-slim`. Install only `bash`, `ca-certificates`, `curl`, `git`, `xz-utils`, `unzip`, and build/runtime libraries required by Flutter web tests. Download:

```text
https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.44.7-stable.tar.xz
```

Verify SHA-256 exactly:

```text
a0edd646c159c0e816788c0e46a4f071199c1320495898f5a679599b583a05a4
```

Create an unprivileged `flutter` user, place the SDK at `/opt/flutter`, run `flutter config --no-analytics --enable-web`, and pre-cache web artifacts.

- [ ] **Step 4: Run the version test and a production web build**

Run:

```bash
docker build -f ops/production/flutter/Dockerfile -t mixli-flutter-builder:test ops/production/flutter
docker run --rm mixli-flutter-builder:test flutter --version --machine
docker run --rm -v "$PWD:/workspace" -w /workspace mixli-flutter-builder:test bash -lc 'flutter pub get --enforce-lockfile && flutter analyze && flutter test && cd apps/mosaic_app && flutter build web --release --pwa-strategy=none'
```

Expected: reported versions match and the web build exits 0 with files under `apps/mosaic_app/build/web`.

- [ ] **Step 5: Commit**

```bash
git add ops/production/flutter ops/production/tests/flutter_image.bats
git commit -m "ops: pin Flutter production builder"
```

### Task 4: Define PostgreSQL and pgBackRest

**Files:**
- Create: `ops/production/postgres/Dockerfile`
- Create: `ops/production/postgres/postgresql.conf`
- Create: `ops/production/postgres/pgbackrest.conf.example`
- Create: `ops/production/tests/postgres_backup.bats`

- [ ] **Step 1: Write a failing local backup/restore integration test**

Start the test PostgreSQL image with temporary data and repository volumes, create the `mixli` stanza, insert a sentinel row, run a full local backup, delete the test cluster, restore it, and assert the sentinel row exists. Keep R2 disabled in this local test.

- [ ] **Step 2: Verify the image test fails**

Run: `docker build -f ops/production/postgres/Dockerfile -t mixli-postgres:test ops/production/postgres`

Expected: non-zero status because the Dockerfile is missing.

- [ ] **Step 3: Build PostgreSQL 18.3 with pgBackRest**

Base on `postgres:18.3-bookworm`, install `pgbackrest` from the configured Debian/PGDG packages, and keep the upstream entrypoint. Mount persistent data at `/var/lib/postgresql`, matching the PostgreSQL 18 official-image layout (`PGDATA=/var/lib/postgresql/18/docker`).

- [ ] **Step 4: Add conservative database configuration**

Set exact initial values:

```conf
listen_addresses = '*'
max_connections = 100
shared_buffers = 8GB
effective_cache_size = 20GB
maintenance_work_mem = 512MB
work_mem = 16MB
wal_compression = on
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
archive_mode = on
archive_command = 'pgbackrest --stanza=mixli archive-push %p'
archive_timeout = 300
log_checkpoints = on
log_lock_waits = on
log_min_duration_statement = 500
```

Do not enable aggressive kernel or huge-page settings until storage and load measurements exist.

- [ ] **Step 5: Add the credential-free pgBackRest contract**

Configure stanza `mixli`, local `repo1` at `/var/lib/pgbackrest`, and R2 `repo2` with `repo2-type=s3`, region `auto`, path-style URIs, AES-256-CBC repository encryption, bundle/block support, two retained full backup chains, and environment-supplied endpoint, bucket, key, secret, and cipher passphrase. Never commit those values.

- [ ] **Step 6: Run the local backup/restore test**

Run: `docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/postgres_backup.bats`

Expected: backup, restore, and sentinel validation pass.

- [ ] **Step 7: Commit**

```bash
git add ops/production/postgres ops/production/tests/postgres_backup.bats
git commit -m "ops: add PostgreSQL recovery image"
```

### Task 5: Define the production Compose topology

**Files:**
- Create: `ops/production/compose.yaml`
- Create: `ops/production/env/production.env.example`
- Create: `ops/production/runtime/api-upstream.example.conf`
- Create: `ops/production/tests/compose_config.bats`

- [ ] **Step 1: Write a failing Compose contract test**

Assert that rendered Compose config contains PostgreSQL with no published port, four API services with no published ports, Nginx as the only service publishing 80/443, private `backend` and `monitoring` networks, health checks, read-only application filesystems, `no-new-privileges`, and explicit memory limits.

- [ ] **Step 2: Verify the test fails**

Run: `docker compose --env-file ops/production/env/production.env.example -f ops/production/compose.yaml config`

Expected: non-zero status because the Compose file is missing.

- [ ] **Step 3: Create the runtime environment contract**

Use concrete non-secret defaults for project name, domains, active pool, release root, database name/user, log level, and image tags. Represent secrets with file paths under `/etc/mixli/secrets`; do not include example secret values that could accidentally be used in production.

- [ ] **Step 4: Define blue and green API pools**

Create `api-blue-1`, `api-blue-2`, `api-green-1`, and `api-green-2`. Each uses an image variable for its pool, reads the database URL from the root-owned environment, exposes only port 8080 to the backend network, runs as a non-root user with a read-only root filesystem and tmpfs `/tmp`, and has a `/ready` health check. Set a 1 GiB memory limit and 0.75 CPU reservation per replica.

- [ ] **Step 5: Define PostgreSQL and Nginx services**

PostgreSQL mounts `/srv/mixli/data/postgres` at `/var/lib/postgresql`, local pgBackRest storage at `/srv/mixli/backups/pgbackrest`, and root-owned configuration/secrets read-only. Set a 16 GiB memory limit. Nginx mounts the complete `/srv/mixli` release/state tree read-only, publishes 80/443, and receives only the origin certificate/key and runtime upstream include.

- [ ] **Step 6: Render and inspect the Compose contract**

Run:

```bash
docker compose --env-file ops/production/env/production.env.example -f ops/production/compose.yaml config --quiet
docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/compose_config.bats
```

Expected: config validation and all contract tests pass.

- [ ] **Step 7: Commit**

```bash
git add ops/production/compose.yaml ops/production/env ops/production/runtime ops/production/tests/compose_config.bats
git commit -m "ops: define production service topology"
```

### Task 6: Configure Nginx for web, API, operations, and future sockets

**Files:**
- Create: `ops/production/nginx/nginx.conf`
- Create: `ops/production/nginx/conf.d/mixli.conf`
- Create: `ops/production/tests/nginx_config.bats`

- [ ] **Step 1: Write failing Nginx behavior tests**

Cover configuration validation, apex web fallback to `index.html`, immutable cache headers for hashed assets, revalidation for `index.html`, `www` redirect, API proxy headers, request ID propagation, passive upstream retry, `/nginx-health`, WebSocket upgrade headers, and denial of the operations virtual host without the Cloudflare Access assertion header.

- [ ] **Step 2: Verify the tests fail before configuration exists**

Run: `docker run --rm -v "$PWD/ops/production/nginx:/etc/nginx:ro" nginx:1.28.0-alpine nginx -t`

Expected: non-zero status because configuration files are missing.

- [ ] **Step 3: Create global Nginx configuration**

Use `worker_processes auto`, JSON access logs, bounded client bodies/timeouts, `server_tokens off`, a `map` for `$connection_upgrade`, and Cloudflare real-IP includes generated at provisioning time. Keep proxy buffering enabled for ordinary API responses and explicitly configure WebSocket upgrade behavior.

- [ ] **Step 4: Create the virtual hosts**

Configure:

- `mixli.app`: Flutter root under `/srv/mixli/current/web`, `try_files $uri $uri/ /index.html`, immutable caching only for hashed assets, and security headers;
- `www.mixli.app`: 308 redirect to the apex preserving the URI;
- `api.mixli.app`: proxy to `mixli_api`, retry only idempotent-safe transport failures, pass request/forwarded IDs, and expose `/nginx-health` without touching the API;
- `ops.mixli.app`: proxy Grafana and require the Cloudflare Access JWT header at Nginx in addition to the Cloudflare Access policy.

- [ ] **Step 5: Run configuration and behavior tests**

Run the Bats suite with a temporary Compose project and then run `nginx -t` inside the actual Nginx image.

Expected: all tests and Nginx syntax validation pass.

- [ ] **Step 6: Commit**

```bash
git add ops/production/nginx ops/production/tests/nginx_config.bats
git commit -m "ops: configure production Nginx"
```

### Task 7: Implement the blue/green deployment runner

**Files:**
- Create: `ops/production/bin/deployment.sh`
- Create: `ops/production/tests/deployment.bats`

- [ ] **Step 1: Write failing deployment state-machine tests**

Use command shims and temporary directories to test SHA validation, production-branch ancestry validation, exclusive locking, inactive-pool selection, repeated readiness requirements, no switch on build failure, no switch on migration failure, atomic web symlink switch, atomic Nginx include switch, rollback after public smoke failure, release record creation, and bounded retention that never removes the current or previous release.

- [ ] **Step 2: Verify the missing runner fails**

Run: `docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/deployment.bats`

Expected: non-zero status because `deployment.sh` is missing.

- [ ] **Step 3: Implement strict preflight and build stages**

Use `set -Eeuo pipefail`, `umask 027`, `flock /run/lock/mixli-deploy.lock`, an error trap, and absolute paths. Require a 40-character lowercase SHA, fetch `origin main`, verify `git merge-base --is-ancestor "$sha" origin/main`, and create `/srv/mixli/builds/$sha` as the unprivileged `mixli-build` account.

Run the existing Node and Flutter checks in the pinned builders. Build the API image as `mixli-api:$sha`. Copy the Flutter output into `/srv/mixli/releases/$sha/web` and write release metadata containing SHA and UTC build time.

- [ ] **Step 4: Implement migration and pool switching**

Run a pgBackRest check and incremental pre-migration backup, execute `node dist/db/migrate.js up` once from the candidate API image, start both replicas in the inactive pool, and require five consecutive `/ready` successes per replica. Generate the upstream file in the same directory and replace it with `mv`, run `nginx -t`, reload Nginx, then replace the `current` web symlink atomically.

- [ ] **Step 5: Implement smoke rollback and drain**

Probe origin hostnames with explicit Host headers and public Cloudflare URLs. On failure after switch, restore the prior upstream include and web symlink, validate/reload Nginx, and preserve the failed release logs. On success, wait a maximum of 90 seconds, stop the old pool, record `current.json` and `previous.json`, and keep the five newest non-current release directories/images.

- [ ] **Step 6: Run deployment tests and ShellCheck**

Run:

```bash
docker run --rm -v "$PWD:/repo" -w /repo bats/bats:1.12.0 ops/production/tests/deployment.bats
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 ops/production/bin/deployment.sh
```

Expected: tests and ShellCheck exit 0.

- [ ] **Step 7: Commit**

```bash
git add ops/production/bin/deployment.sh ops/production/tests/deployment.bats
git commit -m "ops: add exact-SHA blue-green deployer"
```

### Task 8: Implement backup scheduling and restore verification

**Files:**
- Create: `ops/production/bin/backup.sh`
- Create: `ops/production/bin/restore-verify.sh`
- Create: `ops/production/systemd/mixli-backup-full.service`
- Create: `ops/production/systemd/mixli-backup-full.timer`
- Create: `ops/production/systemd/mixli-backup-incr.service`
- Create: `ops/production/systemd/mixli-backup-incr.timer`
- Create: `ops/production/systemd/mixli-backup-check.service`
- Create: `ops/production/systemd/mixli-backup-check.timer`
- Create: `ops/production/systemd/mixli-restore-verify.service`
- Create: `ops/production/systemd/mixli-restore-verify.timer`
- Create: `ops/production/tests/backup_scripts.bats`

- [ ] **Step 1: Write failing command/locking tests**

Test that backup types are limited to `full`, `incr`, and `check`; every operation locks; failures propagate; successful runs emit a Prometheus textfile timestamp; and restore verification refuses to touch the production data path.

- [ ] **Step 2: Implement backup commands**

`backup.sh full` and `backup.sh incr` run against both local and R2 repositories, followed by `check`; `check` validates stanza/archive state and emits `/srv/mixli/metrics/pgbackrest.prom`. Use a separate backup lock so a scheduled job cannot overlap a pre-migration backup.

- [ ] **Step 3: Implement isolated restore verification**

Restore the newest R2 backup into `/srv/mixli/restore-tests/$(date -u +%Y%m%dT%H%M%SZ)`, start an isolated PostgreSQL container without public ports, run `pg_isready`, migration status, and sentinel catalog queries, then stop it. Delete only the verified absolute restore-test path after resolving it beneath `/srv/mixli/restore-tests`.

- [ ] **Step 4: Add timers**

Schedule incremental backups daily at 02:15 WAT, full backups Sunday at 01:15 WAT, repository checks every six hours, and isolated restore verification on the first Sunday of each month at 03:30 WAT. Set `Persistent=true`, randomized delays, and service timeouts.

- [ ] **Step 5: Run tests and validate units**

Run Bats, ShellCheck, and `systemd-analyze verify ops/production/systemd/*` on Debian.

Expected: all exit 0.

- [ ] **Step 6: Commit**

```bash
git add ops/production/bin/backup.sh ops/production/bin/restore-verify.sh ops/production/systemd ops/production/tests/backup_scripts.bats
git commit -m "ops: automate backup and restore verification"
```

### Task 9: Add observability and alert rules

**Files:**
- Modify: `apps/api/package.json`
- Modify: `apps/api/package-lock.json`
- Modify: `apps/api/src/app.ts`
- Create: `apps/api/src/metrics.ts`
- Create: `apps/api/test/metrics.test.ts`
- Modify: `ops/production/compose.yaml`
- Create: `ops/production/prometheus/prometheus.yml`
- Create: `ops/production/prometheus/rules.yml`
- Create: `ops/production/alertmanager/alertmanager.yml`
- Create: `ops/production/grafana/provisioning/datasources/prometheus.yml`
- Create: `ops/production/grafana/provisioning/dashboards/mixli-overview.json`
- Create: `ops/production/tests/monitoring_config.bats`

- [ ] **Step 1: Write failing configuration tests**

Use `promtool` and `amtool` containers to validate syntax. Assert scrape targets exist for Prometheus, node exporter, cAdvisor, Nginx exporter, PostgreSQL exporter, and the backup textfile collector.

- [ ] **Step 2: Add tested API metrics**

Run `npm install --save-exact prom-client@15.1.3` under `apps/api`. First add failing inject-based tests that require `/metrics` to expose request count and duration histograms labelled only by method, normalized route, and status class, plus a `mixli_release_info` gauge. Implement a dedicated registry in `src/metrics.ts`, attach hooks in `buildApp`, and expose `/metrics`. Configure Nginx to return 404 for public `/metrics`; Prometheus scrapes the API replicas directly on the private network.

- [ ] **Step 3: Add private monitoring services**

Add Prometheus, Alertmanager, Grafana, node exporter, cAdvisor, Nginx exporter, and PostgreSQL exporter to the private monitoring network. Publish no monitoring port directly. Persist Prometheus/Grafana data under `/srv/mixli/data/monitoring`, apply memory limits, and route only Grafana through `ops.mixli.app` plus Cloudflare Access.

- [ ] **Step 4: Add actionable alert rules**

Define exact rules for target down (2 minutes), API 5xx ratio above 2% (5 minutes), API p95 above 500 ms (10 minutes), disk below 15%, memory below 10%, repeated container restarts, PostgreSQL exporter down, connections above 80%, backup older than 26 hours, WAL archive older than 15 minutes, and failed restore verification older than 35 days.

- [ ] **Step 5: Provision the baseline dashboard**

Create a version-controlled Grafana dashboard showing public/API availability, request rate, error ratio, p50/p95/p99 duration, active release SHA, replica health/restarts, host CPU/memory/disk, PostgreSQL connections/transactions/locks/checkpoints, and backup/WAL/restore freshness. Use the provisioned Prometheus datasource UID rather than a dashboard-local datasource.

- [ ] **Step 6: Configure alert delivery contract**

Route alerts to a root-owned external webhook URL supplied in `/etc/mixli/secrets/alertmanager-webhook-url`. Configure Cloudflare-origin and certificate alerts to the Cloudflare account notification address. If Cloudflare Health Checks requires a paid activation, stop before purchase and obtain explicit approval for the displayed charge.

- [ ] **Step 7: Validate monitoring configuration**

Run `promtool check config`, `promtool check rules`, `amtool check-config`, and the Bats contract suite.

Expected: all exit 0.

- [ ] **Step 8: Commit**

```bash
git add apps/api/package.json apps/api/package-lock.json apps/api/src/app.ts apps/api/src/metrics.ts apps/api/test/metrics.test.ts ops/production/compose.yaml ops/production/prometheus ops/production/alertmanager ops/production/grafana ops/production/tests/monitoring_config.bats
git commit -m "ops: add production observability"
```

### Task 10: Automate host provisioning and Cloudflare IP allowlisting

**Files:**
- Create: `ops/production/bin/provision-host.sh`
- Create: `ops/production/bin/update-cloudflare-ips.sh`
- Create: `ops/production/systemd/mixli-stack.service`
- Create: `ops/production/systemd/mixli-cloudflare-ips.service`
- Create: `ops/production/systemd/mixli-cloudflare-ips.timer`
- Create: `ops/production/tests/provisioning.bats`

- [ ] **Step 1: Write failing idempotency and firewall-render tests**

In test mode, use a temporary root and command shims. Assert a second provisioning run makes no semantic changes, Cloudflare lists must contain valid CIDRs and both IPv4/IPv6 entries, an empty/invalid download never replaces the prior allowlist, SSH stays allowed, and Docker-published 80/443 are filtered through `DOCKER-USER`.

- [ ] **Step 2: Implement idempotent provisioning**

Install ca-certificates, curl, git, jq, openssh-server, sudo, fail2ban, unattended-upgrades, nftables, iptables-nft, ipset, and the official Docker Engine/Buildx/Compose packages for Debian 13. Create `mixli`, locked `mixli-build`, and locked `mixli-deploy` accounts plus `/opt/mixli`, `/srv/mixli`, `/etc/mixli`, and `/var/log/mixli` with explicit owners and modes. Clone a build-only mirror at `/srv/mixli/repository`, owned by `mixli-build`, from `https://github.com/pullsar/mosaic` and configure it as the only accepted deployment source.

- [ ] **Step 3: Implement firewall layers safely**

Use nftables for host `INPUT` default-deny rules and key-only SSH access. Because Docker requires the iptables frontend for container forwarding, install origin restrictions in the `DOCKER-USER` chain using validated Cloudflare ipsets. Accept 80/443 only from Cloudflare networks and reject other forwarded access to those published ports. Never rely on UFW rules for Docker-published ports.

- [ ] **Step 4: Add services and sudo boundaries**

Install repository scripts root-owned under `/opt/mixli/bin`. Grant `mixli-deploy` passwordless sudo only for `/opt/mixli/bin/deployment.sh` with arguments; grant no shell or Docker-group membership. Install the stack/IP refresh units, reload systemd, and enable timers without starting production until secrets exist.

- [ ] **Step 5: Test and commit**

Run Bats, ShellCheck, and systemd unit validation, then commit only provisioning files.

```bash
git add ops/production/bin/provision-host.sh ops/production/bin/update-cloudflare-ips.sh ops/production/systemd ops/production/tests/provisioning.bats
git commit -m "ops: automate hardened host provisioning"
```

### Task 11: Add the short GitHub deployment trigger

**Files:**
- Create: `.github/workflows/deploy-production.yml`
- Create: `ops/production/tests/github_workflow.bats`

- [ ] **Step 1: Write a failing workflow contract test**

Assert that the workflow triggers only on `workflow_dispatch` and pushes to `main`, uses a production environment, has `contents: read`, has a concurrency group without cancellation, pins the checkout action if used, has a two-minute timeout, and executes no repository code on the hosted runner.

- [ ] **Step 2: Create the workflow**

Use a standard Ubuntu runner only to install the private key from `MIXLI_DEPLOY_SSH_KEY`, install the exact known-host line from `MIXLI_DEPLOY_KNOWN_HOST`, and run:

```bash
ssh -o BatchMode=yes -o IdentitiesOnly=yes mixli-deploy@152.53.55.38 "deploy ${GITHUB_SHA}"
```

Do not use a third-party SSH action. Never disable host-key checking. Configure `environment: production` so GitHub environment protections can gate deployment.

- [ ] **Step 3: Validate and commit**

Run the workflow contract test and a YAML parser, then commit.

```bash
git add .github/workflows/deploy-production.yml ops/production/tests/github_workflow.bats
git commit -m "ci: add restricted production deploy trigger"
```

### Task 12: Write operating and recovery procedures

**Files:**
- Create: `ops/production/README.md`
- Create: `ops/production/bin/verify-production.sh`
- Create: `ops/production/tests/verify_script.bats`

- [ ] **Step 1: Write failing verification-script tests**

Test command availability checks, expected HTTP/TLS assertions, API release-header matching, container health checks, migration status, backup/WAL freshness, firewall checks, and non-zero exit when any assertion fails.

- [ ] **Step 2: Implement repeatable production verification**

The script must support `--origin` and `--public` modes. It prints a concise pass/fail line per requirement and a final count, never prints environment values, and exits non-zero on any failure.

- [ ] **Step 3: Document exact runbooks**

Document initial provisioning, required secret files and modes, manual deployment, GitHub-triggered deployment, compatible rollback, migration-forward repair, R2 credential rotation, origin certificate rotation, admin/deploy key rotation, backup verification, point-in-time restore, total-host rebuild, log/metric locations, and incident triage. Include commands and expected evidence for every operation.

- [ ] **Step 4: Test and commit**

Run Bats and ShellCheck, scan the README for placeholders, then commit.

```bash
git add ops/production/README.md ops/production/bin/verify-production.sh ops/production/tests/verify_script.bats
git commit -m "docs: add production operations runbook"
```

### Task 13: Run the complete repository verification before remote changes

**Files:**
- Modify only files required to fix failures introduced by Tasks 1-12.

- [ ] **Step 1: Run all production tests**

Run every Bats suite, ShellCheck over every shell file, `docker compose config`, Nginx validation, `promtool`, `amtool`, and `systemd-analyze verify`.

Expected: zero test/configuration failures.

- [ ] **Step 2: Run the application CI commands**

Run API `npm ci --ignore-scripts`, typecheck, tests, and build with PostgreSQL 18. Run the pinned Flutter builder with locked dependency resolution, formatting check, analysis, package tests, app tests, and production web build.

Expected: every committed CI command exits 0.

- [ ] **Step 3: Inspect repository state**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -15
```

Expected: only the unrelated user-owned `mixli-brand-kit-v2/` remains untracked; it is never staged, copied into images, uploaded, or modified.

### Task 14: Create production keys and configure Cloudflare/Porkbun

**Files:**
- Create outside repository: `C:\keys\mixli-prod`
- Create outside repository: `C:\keys\mixli-prod.pub`
- Create outside repository: `C:\keys\mixli-github-deploy`
- Create outside repository: `C:\keys\mixli-github-deploy.pub`

- [ ] **Step 1: Generate dedicated keys**

Create Ed25519 keys with clear comments and strong local file permissions. Never overwrite an existing path; if either target exists, inspect it and stop for direction.

- [ ] **Step 2: Repair the Cloudflare zone and registrar delegation**

Using the user-authorized Computer capability, add or inspect the `mixli.app` Cloudflare zone, record the assigned nameservers, and update Porkbun delegation. DNSSEC must be either correctly re-established after delegation or disabled at the registrar until the Cloudflare DS record is active; leaving a stale DS that causes `SERVFAIL` is forbidden.

- [ ] **Step 3: Create DNS, TLS, and Access configuration**

Create proxied apex, `www`, `api`, and `ops` records; set Full (strict); create an Origin CA certificate; configure the apex redirect; enable available WAF/rate-limit protections; and create a Cloudflare Access application for `ops.mixli.app` limited to the user's Cloudflare identity.

- [ ] **Step 4: Create R2 backup resources**

Create bucket `mixli-production-backups` in the jurisdiction selected in the dashboard. Create a long-lived account token scoped to Object Read & Write for that bucket only. Record the account ID, endpoint, Access Key ID, and one-time Secret Access Key directly into the root-owned server secret file without placing them in chat, logs, screenshots, Git, or shell history.

- [ ] **Step 5: Configure external monitoring**

Create a Cloudflare health check for `https://api.mixli.app/health` and notification routing if included in the account. If the dashboard requires a purchase, stop at the displayed checkout and request explicit approval before completing it.

### Task 15: Provision and harden the server without lockout

**Files:**
- Install repository-controlled files under `/opt/mixli` and `/etc/systemd/system`.
- Create root-owned secrets under `/etc/mixli/secrets`.

- [ ] **Step 1: Install and verify the administrator key**

Use the existing root session to create `mixli`, install `mixli-prod.pub`, and set the sudo authentication method. Open a second independent key-based session, run a harmless sudo command, and keep both sessions open.

- [ ] **Step 2: Run provisioning and inspect changes**

Run `provision-host.sh`, review installed package versions, directory ownership, Docker status, firewall rules, systemd units, and pending reboot state. Run it a second time and verify idempotence.

- [ ] **Step 3: Install deployment authentication**

Install the GitHub deploy public key with forced command, no PTY, and forwarding disabled. Verify an allowed test invocation and verify interactive/arbitrary commands fail.

- [ ] **Step 4: Harden SSH in a drop-in**

Set `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`, `X11Forwarding no`, `AllowAgentForwarding no`, and `AllowUsers mixli mixli-deploy`. Run `sshd -t`, reload SSH, then prove a new admin key session works and root/password sessions fail before closing the original root session.

- [ ] **Step 5: Enable security maintenance**

Enable unattended security upgrades without automatic reboot, configure Fail2ban, create a 4 GiB encrypted swap file with low swappiness, cap journald/Docker log storage, and validate time synchronization.

### Task 16: Install secrets, initialize data, and perform the first deployment

**Files:**
- Create server-only: `/etc/mixli/env/production.env`
- Create server-only: `/etc/mixli/secrets/*`
- Create server-only: `/srv/mixli/state/nginx/api-upstream.conf`

- [ ] **Step 1: Generate server-only credentials**

Generate independent high-entropy PostgreSQL, Grafana, pgBackRest cipher, and internal exporter credentials. Write each with mode 0600 and correct owner. Do not reuse the supplied initial root password.

- [ ] **Step 2: Install Cloudflare and R2 secrets**

Install the Origin CA certificate/key and bucket-scoped R2 credentials without printing them. Test R2 list/write/read/delete access against a disposable object in the backup prefix and verify access outside the bucket/prefix is denied where the Cloudflare scope permits that test.

- [ ] **Step 3: Start PostgreSQL and create the backup stanza**

Start only PostgreSQL, wait for readiness, create the `mixli` stanza in both repositories, run `pgbackrest check`, then complete and verify the first full backup to local storage and R2.

- [ ] **Step 4: Deploy the exact current approved SHA**

Push or otherwise make the committed deployment assets reachable from upstream `main`, fetch the server mirror, then run `sudo /opt/mixli/bin/deployment.sh "$(git -C /srv/mixli/repository rev-parse origin/main)"`. Record the resolved SHA used; do not deploy an unpushed local-only commit because the runner requires ancestry from upstream `main`.

- [ ] **Step 5: Enable scheduled services**

Enable/start the stack, backup, repository-check, restore-drill, and Cloudflare-IP refresh timers. Confirm their next-run timestamps and run each service once manually.

### Task 17: Configure GitHub production deployment

**Files:**
- GitHub repository environment: `production`.

- [ ] **Step 1: Create GitHub environment secrets**

Using an authenticated GitHub session or CLI, create `MIXLI_DEPLOY_SSH_KEY` from the dedicated deployment private key and `MIXLI_DEPLOY_KNOWN_HOST` from the already verified server ED25519 host key. Add production environment protection appropriate to the repository owner.

- [ ] **Step 2: Exercise manual dispatch**

Run the workflow against the current `main` SHA and verify the GitHub-hosted portion only performs the restricted SSH trigger while the server logs contain the build/test/deploy work.

- [ ] **Step 3: Exercise push-to-main behavior deliberately**

After confirming the owner wants automatic production deployment on every main push, enable the push trigger and use a documentation-only canary commit. If automatic production on every push is not desired, retain only `workflow_dispatch`; do not infer this policy from the workflow's existence.

### Task 18: Perform destructive-safe failure and recovery acceptance tests

**Files:**
- Append evidence and actual timings to `ops/production/README.md` only if the runbook reserves an evidence section.

- [ ] **Step 1: Verify replica continuity**

Stop one active API replica, send repeated requests through Cloudflare, and confirm no failed health/API response. Restore it and repeat with the other replica.

- [ ] **Step 2: Verify failed-candidate isolation**

Use the deployment test hook to make candidate readiness fail. Confirm Nginx upstream and current web symlink remain on the active SHA.

- [ ] **Step 3: Verify compatible rollback**

Deploy two schema-compatible releases, roll back to the previous release, and confirm public web/API health and recorded SHA.

- [ ] **Step 4: Verify R2 restore**

Run the isolated restore service, confirm the restored database becomes ready, check migration status and sentinel data, and confirm the production PostgreSQL data directory was never opened or modified by the restore container.

- [ ] **Step 5: Verify reboot recovery**

After confirming backups and console/recovery access, perform one controlled reboot. Verify SSH, Docker, PostgreSQL, API replicas, Nginx, monitoring, timers, and public endpoints recover automatically.

- [ ] **Step 6: Establish a performance baseline**

Run bounded origin and Cloudflare tests against `/health`, `/ready`, and an immutable Play revision endpoint. Record p50/p95/p99 latency, throughput, errors, CPU, memory, database connections, and Nginx upstream behavior. Do not run an unbounded load test against production.

### Task 19: Final verification and handoff

**Files:**
- Modify documentation only when actual production facts differ from the committed runbook.

- [ ] **Step 1: Run the full verification script freshly**

Run both:

```bash
sudo /opt/mixli/bin/verify-production.sh --origin
sudo /opt/mixli/bin/verify-production.sh --public
```

Expected: zero failed assertions.

- [ ] **Step 2: Verify backup evidence freshly**

Run pgBackRest `info`, `check`, and the isolated restore service. Confirm current R2 objects and WAL freshness without displaying credentials.

- [ ] **Step 3: Verify security evidence freshly**

Inspect effective `sshd -T`, nftables, `DOCKER-USER`, listening sockets, failed systemd units, container health, pending security upgrades/reboot, and Cloudflare strict TLS.

- [ ] **Step 4: Reconcile requirements line by line**

Compare the live evidence to every acceptance item in `docs/superpowers/specs/2026-08-28-mixli-production-deployment-design.md`. Report any gap plainly; do not mark production complete because only application tests pass.

- [ ] **Step 5: Commit final factual documentation changes**

Run documentation placeholder and diff checks, then commit only the runbook evidence/factual corrections. Leave the user-owned `mixli-brand-kit-v2/` directory untouched.
