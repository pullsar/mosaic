# Mixli Production Deployment Design

**Status:** Approved on 2026-08-28

## 1. Purpose

Deploy the current `pullsar/mosaic` `main` branch as the production foundation for `mixli.app` on the Debian server at `152.53.55.38`. The design prioritizes reliability, predictable recovery, security, and measured performance while keeping the initial system proportionate to Mosaic's current milestone.

The public surface is:

- `mixli.app`: the Flutter web application;
- `www.mixli.app`: a permanent redirect to `mixli.app`;
- `api.mixli.app`: the Fastify API.

The implementation must pin every release to an exact Git commit and must not depend on mutable `latest` tags for production application artifacts.

## 2. Constraints and success criteria

The initial production system has one origin server with 12 vCPUs, 31 GiB RAM, and approximately 1 TiB of storage. A single server cannot provide infrastructure high availability. The design therefore maximizes service continuity during application deployments and provides fast, tested recovery from origin or database loss.

Success means:

- the public web and API surfaces use Cloudflare-proxied strict TLS;
- routine application deployments do not interrupt healthy API requests;
- a failed build, migration preflight, or readiness check does not switch traffic;
- root and password-based SSH access are disabled only after key-based administrator access is verified;
- PostgreSQL has continuous offsite recovery data in Cloudflare R2;
- the system restarts cleanly after a host reboot;
- monitoring detects application, database, capacity, deployment, and backup failures;
- deployment and rollback procedures are deterministic and recorded by release SHA.

## 3. Architecture

```text
Users
  -> Cloudflare DNS, proxy, WAF, TLS, compression, and cache
      -> mixli.app / www.mixli.app
          -> Nginx
              -> atomic Flutter web release symlink
      -> api.mixli.app
          -> Nginx
              -> active two-replica API pool A or B
                  -> PostgreSQL
                      -> pgBackRest repository and continuous WAL archive
                          -> local backup repository
                          -> Cloudflare R2 offsite repository
```

Nginx is the origin proxy because Cloudflare supplies the edge TLS and caching functions that would otherwise make Caddy's automatic certificate management particularly valuable. Nginx provides efficient static delivery, bounded proxy behavior, and configuration-tested graceful reloads.

Docker Compose manages the application, database, and observability services. Images and runtime versions are pinned. Docker's restart policies and a systemd unit bring the stack back after a reboot. Automatic container-update agents are not used; updates pass through the controlled deployment path.

## 4. Cloudflare and DNS

Cloudflare becomes the authoritative DNS provider for `mixli.app`. The existing DNS `SERVFAIL` condition must be repaired before production validation. Porkbun remains the registrar and is updated with the Cloudflare-assigned nameservers.

Required proxied DNS records are:

- apex `mixli.app` -> `152.53.55.38`;
- `www.mixli.app` -> apex redirect behavior;
- `api.mixli.app` -> `152.53.55.38`.

Cloudflare SSL/TLS mode is Full (strict). The origin uses a Cloudflare Origin CA certificate covering the apex and required subdomains. Authenticated Origin Pulls is enabled when supported by the active Cloudflare plan and configuration. The origin firewall accepts HTTP and HTTPS only from Cloudflare's published IP ranges. Direct PostgreSQL and API container ports are never public.

Cloudflare caching behavior is explicit:

- hashed Flutter assets receive long-lived immutable caching;
- `index.html`, the web manifest, and service-worker metadata remain short-lived or revalidated so deployments propagate promptly;
- API responses are not cached by default;
- immutable public Play/media responses may opt into edge caching later through explicit response headers;
- authenticated and mutation responses are never edge cached.

Grafana, if exposed through a hostname, is protected with Cloudflare Access and is not anonymously reachable.

## 5. Host access and hardening

A dedicated `mixli` administrator is created. A new Ed25519 administrator keypair is stored at `C:\keys\mixli-prod` and `C:\keys\mixli-prod.pub`. An unrelated historical key is not reused.

The hardening sequence is intentionally fail-safe:

1. Create the administrator and install the public key.
2. Grant the required sudo access.
3. Verify a new independent key-based SSH session and sudo operation.
4. Keep the verified session open while applying SSH changes.
5. Disable root SSH, passwords, keyboard-interactive authentication, X11 forwarding, and unnecessary forwarding features.
6. Verify allowed and rejected login paths before closing the recovery session.

The nftables firewall defaults to denying unsolicited inbound traffic. SSH remains a key-only recovery path on port 22 and is protected by Fail2ban. HTTP and HTTPS accept Cloudflare source networks only after DNS and proxy reachability are verified. Outbound traffic is allowed for package retrieval, GitHub, R2, DNS, time synchronization, and required telemetry.

Debian unattended security updates are enabled. The single origin is not permitted to reboot unexpectedly; required reboots generate an alert and are performed in a controlled maintenance window. Time synchronization, log rotation, journald retention, and Docker storage limits are configured.

Application secrets live in root-owned files outside Git with restrictive permissions. Secrets, tokens, connection strings, and sensitive request payloads are excluded from logs.

## 6. Runtime and resource isolation

The production stack contains:

- Nginx origin proxy;
- one active two-replica API pool and one inactive release pool that is started with two replicas during deployment;
- PostgreSQL;
- pgBackRest backup jobs and WAL archiving;
- Prometheus and required exporters;
- Grafana;
- Alertmanager or the selected external alert integration.

API instances listen only on the private container network. Nginx is the only public application entrypoint. Each API instance exposes `/health` for process liveness and `/ready` for PostgreSQL-backed readiness.

Container memory and restart limits prevent an API or observability leak from starving PostgreSQL. A small encrypted swap file provides emergency protection from abrupt out-of-memory termination but is not treated as normal application capacity.

PostgreSQL tuning is conservative and based on measured host storage and workload behavior. The initial configuration preserves substantial memory for the Linux filesystem cache, uses bounded API connection pools, and does not add Redis, PgBouncer, or a separate queue without measured need.

## 7. Deployment runner

`deployment.sh` is a root-owned server-side deployment runner. It accepts an exact commit SHA and performs the expensive CI and release work on the origin. It supports manual invocation by the administrator and a short GitHub Actions trigger.

The deployment sequence is:

1. Acquire an exclusive `flock` deployment lock.
2. Validate the requested SHA format and record the initiating principal.
3. Fetch the configured GitHub origin and verify that the SHA is reachable from the allowed production branch.
4. Create an isolated release/build workspace owned by an unprivileged build account.
5. Resolve locked Node and Flutter dependencies.
6. Run API typechecking, unit/integration tests, and the production build.
7. Run the committed Flutter formatting, analysis, package tests, app test, and production web build.
8. Build immutable production application artifacts labelled with the exact SHA.
9. Validate Nginx and Compose configuration before changing live state.
10. Confirm PostgreSQL readiness and complete a pre-migration backup checkpoint.
11. Run forward migrations once under an advisory/exclusive deployment lock.
12. Start the inactive API slot with the new release.
13. Require repeated successful `/health` and `/ready` probes within a bounded timeout.
14. Switch Nginx to the new API slot with a configuration-tested graceful reload.
15. Atomically switch the Flutter web release symlink.
16. Run origin and public smoke tests.
17. Drain and stop the old API slot after a bounded grace period.
18. Record the deployed SHA, migration state, timestamps, health results, and initiator.
19. Retain a bounded number of prior artifacts and remove older artifacts without touching persistent data.

If a step before traffic switch fails, the live release is unchanged. If public smoke tests fail after switching, the runner restores the previous API pool and web symlink. Database migrations are forward-first; application rollback is permitted only when the previous application release is compatible with the migrated schema. Otherwise a new forward repair is required.

The GitHub workflow performs only a restricted remote trigger and therefore consumes little hosted-runner time. Its dedicated SSH key does not grant an interactive shell. The server's `authorized_keys` entry forces a root-owned dispatcher, rejects port/agent/X11 forwarding, validates the requested SHA, and invokes the deployment runner through narrowly scoped privileges. Manual deployment uses the verified administrator account.

## 8. Realtime communication

The current product scope does not require persistent bidirectional connections. Challenges and feed activity are asynchronous; livestreaming and multiplayer beyond sharing/challenges are deferred. The initial deployment therefore keeps REST and PostgreSQL authoritative.

Initial rules are:

- durable changes and events are committed idempotently before any notification is emitted;
- challenge responses and feed changes use normal API requests;
- foreground freshness begins with conditional polling or Server-Sent Events when polling is insufficient;
- mobile background delivery may use APNs and FCM as push transports;
- Firebase Realtime Database and Firestore are not application sources of truth.

Nginx is configured so WebSocket upgrades can be added without replacing the proxy. When true bidirectional realtime becomes a product requirement, connections terminate in stateless API instances. A shared Redis, NATS, or managed fan-out service is added only when multiple instances must distribute transient messages.

PostgreSQL remains the durable source of truth. Realtime messages are delivery hints. Clients reconnect with exponential backoff and resynchronize over REST so deployment rotations or dropped connections cannot lose product state. Long-lived connections have a bounded lifetime, and the deployment runner drains an old pool for a bounded interval instead of waiting indefinitely.

## 9. PostgreSQL backup and recovery

PostgreSQL uses persistent storage independent of application releases. pgBackRest produces checksummed, compressed backups and continuous WAL archives. The repository design includes a recent local copy for fast recovery and an offsite Cloudflare R2 copy for server-loss recovery.

The initial schedule is:

- continuous WAL archiving;
- daily incremental backups;
- weekly full backups;
- automated repository integrity checks after scheduled backups;
- monthly restore validation into an isolated temporary database;
- retention bounded by recovery objectives and R2 cost, with at least two verified full backup chains retained offsite.

Backup credentials are scoped to the dedicated R2 bucket and are not shared with application runtime credentials. Backup success requires both a completed backup and fresh WAL archive evidence. Alerts fire for failed backups, missing/stale WAL archives, repository verification errors, retention errors, or failed restore validation.

The recovery procedure records the target time or backup set, restores into isolation first where practical, validates migrations and key row counts, then promotes the recovered database through an explicit operator step. Restore commands and expected verification evidence are documented alongside the deployment assets.

## 10. Observability and alerting

Nginx and the API emit structured logs with request IDs, durations, statuses, release SHA, and upstream instance. Secrets and authored/user-sensitive payloads are redacted or omitted.

Prometheus collects:

- host CPU, memory, storage, network, and clock health;
- container availability, restarts, CPU, memory, and storage;
- Nginx request rate, status, and latency;
- API health, readiness, errors, and latency;
- PostgreSQL connections, transactions, locks, replication/archive state, checkpoints, WAL, and storage;
- backup age, duration, verification state, and WAL freshness;
- deployment duration and result by release SHA.

Alerts cover total endpoint unavailability, elevated error rate, latency regression, capacity pressure, repeated container restarts, PostgreSQL unavailability, connection exhaustion, failed deployments, stale backups, missing WAL archives, and certificate expiry. A Cloudflare health check or comparable external heartbeat detects complete origin failure because monitoring hosted only on the origin cannot do so.

## 11. Failure behavior

- One active API replica fails: Nginx avoids or retries the failed upstream while the other replica remains available.
- New release fails before switch: deployment stops and the current release remains live.
- New release fails after switch: web/API artifacts revert to the prior compatible release; logs retain the failed SHA.
- Nginx configuration fails validation: Nginx keeps the prior configuration.
- PostgreSQL is unavailable: `/ready` returns failure, writes stop, and the API does not claim readiness.
- Cloudflare is unavailable: the public service is impaired; the origin remains protected and is not opened broadly as an automatic workaround.
- R2 is unavailable: the application continues, backup/WAL jobs retry with bounds, and stale-archive alerts fire.
- Monitoring is unavailable: product traffic continues and an external check detects the monitoring/origin failure where possible.
- Host is lost: provision a replacement, restore secrets and infrastructure configuration, restore PostgreSQL from R2 to the selected recovery point, deploy the recorded SHA, validate privately, then update or restore Cloudflare routing.

## 12. Validation and acceptance

Production acceptance requires fresh evidence for all of the following:

- the checkout matches the intended upstream `main` SHA;
- administrator key login and sudo work in a new session;
- root, password, and keyboard-interactive SSH logins fail;
- nftables exposes only the intended services;
- the entire stack returns healthy after a controlled reboot;
- apex, `www`, and API DNS behavior is correct;
- public TLS is valid and Cloudflare uses Full (strict);
- direct origin exposure is restricted as designed;
- Flutter navigation fallback and cache headers behave correctly;
- `/health` and `/ready` succeed through the public API hostname;
- stopping either active API replica does not interrupt the other;
- a deliberately failed candidate release does not switch traffic;
- a successful release switches API and web artifacts atomically;
- the previous compatible release rolls back successfully;
- a full backup and new WAL data reach R2 and pass repository verification;
- an isolated restore reaches a consistent database and passes migration/status checks;
- basic latency and concurrency tests establish a recorded baseline;
- logs, metrics, dashboards, and a test alert identify the active release and failure source.

## 13. Evolution path

The next availability step is not more software on the same server. It is a second independent origin and a replicated or managed PostgreSQL service. The current stateless API pools, immutable releases, Cloudflare edge, external backup repository, and reconnect/resynchronization rules are chosen so that this later transition does not require replacing the application architecture.
