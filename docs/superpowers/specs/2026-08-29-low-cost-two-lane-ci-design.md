# Low-Cost Two-Lane CI Design

## Status

Approved in conversation on 2026-08-29. This specification covers CI trigger reconciliation and server-side review isolation. Event-delivery application changes will be reconciled separately after this CI work is complete.

## Goals

- Keep paid GitHub-hosted execution to short dispatch jobs, normally measured in seconds.
- Preserve pre-merge feedback for pull requests without granting untrusted code production authority.
- Keep the protected-main release gate and exact-image deployment guarantees already implemented on the production server.
- Run iOS simulator validation only when requested manually or when a release is published.
- Keep all Linux, Android, web, API, PostgreSQL, Flutter, Dart, IndexedDB, and infrastructure validation on the production server's isolated CI infrastructure.
- Never run repository builds or tests on the developer PC.

## Non-Goals

- This change does not merge the event-delivery feature branch.
- This change does not alter application event-delivery behavior.
- This change does not introduce a general-purpose public CI service.
- This change does not grant fork or branch code access to production secrets, the production Docker socket, sudo, deployment commands, or production data.
- This change does not build signed iOS release artifacts or publish an application to an app store.

## Existing Problem

The newly pushed event-delivery branch reintroduces overlapping GitHub workflows:

- `ci.yml` runs broad Flutter analysis and tests on every branch push and pull request.
- `api-ci.yml` repeats API and analytics validation on matching branch pushes and pull requests.
- `local-recovery-ci.yml` repeats Flutter setup and local-state validation.
- `platform-ci.yml` repeats Flutter analysis, renderer and app tests, Android/web builds, and a macOS iOS build.

For pull-request branches, `push` and `pull_request` triggers can both run, while their concurrency keys use different refs and therefore do not reliably cancel each other. The workflows repeat dependency resolution and Flutter setup and use paid macOS capacity for ordinary development changes.

The local production architecture already has a comprehensive server runner and a protected-main deployment gate. The missing capability is a safe review lane for exact pull-request SHAs.

## Chosen Architecture

The system has two server CI lanes and one exceptional GitHub-hosted platform lane.

### 1. Untrusted review lane

A trusted default-branch workflow handles pull-request lifecycle events through `pull_request_target`. It never checks out, downloads, imports, builds, or executes pull-request content. It validates and transmits only:

- the repository identity `pullsar/mosaic`;
- a decimal pull-request number; and
- a 40-character lowercase head SHA.

The workflow connects with a review-only SSH identity whose forced command can enqueue review CI and do nothing else. It returns after the server reports that the request is queued.

The server fetches `refs/pull/<number>/head`, verifies that it resolves to the supplied SHA, and creates a clean builder-owned checkout. The checkout is executed only inside a private rootless Docker daemon owned by `mixli-build`. It cannot access:

- `/var/run/docker.sock` or another rootful Docker socket;
- sudo or a privileged helper accepting repository-controlled commands;
- `/etc/mixli/secrets`;
- `/srv/mixli/data` or production database volumes;
- deployment commands, release image promotion, or published ports; or
- host networking beyond the explicitly allowed dependency/test requirements.

The review lane runs the complete Linux-capable test matrix, including formatting, analysis, Dart and Flutter tests, API/PostgreSQL integration, IndexedDB Chrome tests, infrastructure contracts, and Linux/web/Android builds. Candidate images created in this lane remain private to its rootless daemon and are destroyed at cleanup.

### 2. Protected release lane

A push to `main` triggers one short GitHub workflow that invokes `deploy <exact-sha>` through the existing production-restricted SSH identity. The server:

1. verifies that the SHA is reachable from `origin/main`;
2. runs the complete release CI gate;
3. verifies and promotes exact candidate image IDs;
4. deploys only after CI success; and
5. performs existing health, rollback, backup, and firewall checks.

The separate automatic `server-ci.yml` main trigger is removed because deployment already runs the full CI gate. Manual server-side `ci <main-sha>` remains available for operators without creating a paid GitHub job.

### 3. Exceptional iOS lane

One macOS workflow runs the iOS simulator build only for:

- explicit `workflow_dispatch`; or
- `release` with activity type `published`.

The release path checks out the tag commit supplied by the release event. The workflow has read-only repository permissions, no production environment, and no deployment credentials.

## GitHub Workflow Reconciliation

The authoritative workflow set after this change is:

- `review-dispatch.yml`: trusted pull-request dispatcher only; no checkout or build.
- `deploy-production.yml`: one protected-main deployment dispatcher.
- `ios-release.yml`: manual or published-release iOS simulator validation.

The following automatic heavyweight workflows are removed rather than merged from the event-delivery branch:

- `ci.yml`;
- `api-ci.yml`;
- `local-recovery-ci.yml`;
- the automatic push/pull-request form of `platform-ci.yml`; and
- `server-ci.yml` as a redundant protected-main dispatcher.

When event-delivery code is reconciled later, its tests and path coverage are added to the server matrices. Its GitHub workflow definitions are not allowed to replace this authoritative set.

## Review Request Boundary

The review dispatcher accepts exactly two positional values: pull-request number and head SHA. Both are validated before any network or filesystem action.

The request flow is:

1. Acquire a short request lock.
2. Fetch only `+refs/pull/<number>/head:refs/mixli/reviews/<number>` as `mixli-build`.
3. Resolve the fetched ref and compare it byte-for-byte with the supplied SHA.
4. Record the SHA as the latest requested revision for the pull request.
5. Cancel and clean an older active review for the same pull request.
6. Queue a bounded transient systemd unit and return `queued`.

A commit object already present in the repository is insufficient. Equality with the freshly fetched pull-request ref is required, preventing a caller from submitting an unrelated SHA.

## Rootless Review Runner

The rootless runner is installed as root-owned, non-writable code outside the repository checkout. Repository-controlled scripts and tests run as `mixli-build` against a private rootless daemon.

Each run receives unique paths beneath the build area and `/run`, a unique Docker socket, and a detached exact-SHA checkout. Startup verifies Docker reports `name=rootless` and the expected private data root before any test begins.

The runner must not call rootful `docker build`, `docker run`, `docker compose`, or `docker load` for review code. API, PostgreSQL, Flutter, test-harness, and Nginx candidates used by review CI are built or loaded only inside the rootless daemon. Root in a rootless user namespace may be used for tests that need Unix ownership semantics; it is never host root.

The rootless matrix is defined once and shared conceptually with the protected-main validation contract so suites cannot silently disappear from one lane. A workflow contract enumerates every required suite, including event-delivery browser and persistence tests after that feature is reconciled.

## Resource and Concurrency Policy

- At most one untrusted review job runs at a time.
- A newer SHA for the same pull request supersedes the older job.
- Review units have a 45-minute wall timeout, a bounded memory limit, a CPU quota, and lower I/O priority than production operations.
- A production deployment may preempt an active review job.
- Review jobs never share Docker state, dependency write caches, worktrees, or generated artifacts with protected release jobs.
- The GitHub dispatcher uses a per-pull-request concurrency group and cancels an obsolete dispatcher invocation.
- The main deployment dispatcher never uses `cancel-in-progress`, preserving ordered production requests.

Exact quota values are selected from server capacity during implementation and locked by unit tests. They must leave sufficient headroom for PostgreSQL, Nginx, monitoring, backup, and operator access.

## GitHub Status Reporting

A dedicated GitHub App is installed only on `pullsar/mosaic`. Its permissions are limited to repository metadata read and Checks or commit-status write. It has no contents, administration, deployment, environment, or secrets permission.

The server stores its private key in a root-only secret file. Nonsecret App and installation IDs are stored separately. The review job reports:

- queued;
- in progress;
- success;
- failure;
- cancelled because a newer SHA superseded it; or
- timed out.

Status API calls use bounded retries with exponential backoff. The authoritative result is also appended to a root-owned server audit log. If GitHub remains unavailable, the job preserves the local result and exits nonzero after retry exhaustion so a stale pending check cannot be mistaken for success. An operator can re-dispatch the current SHA.

## Failure Handling and Cleanup

Cleanup is part of CI success, not a best-effort afterthought. On success, test failure, cancellation, timeout, or signal, the runner must:

1. stop the private daemon process group;
2. remove its socket, runtime directory, data root, image archives, containers, networks, and volumes;
3. remove the detached review checkout and fetched review ref when no active job needs them; and
4. verify the exact private paths and process group are absent.

Cleanup operates only on validated, exact paths with run-specific prefixes. A cleanup failure changes an otherwise successful review to failure and remains in the audit log.

Malformed inputs, pull-request ref mismatch, dirty checkout, missing rootless prerequisites, authority-boundary failure, status-reporting exhaustion, resource-limit termination, or cleanup failure all fail closed. None can fall back to host root, the production Docker daemon, or a release path.

## Test Strategy

Implementation follows RED/GREEN TDD with all execution on the server.

### Workflow contracts

Tests initially fail until they prove:

- no heavyweight workflow runs automatically on arbitrary branch pushes or pull requests;
- `review-dispatch.yml` uses trusted orchestration, performs no checkout, and passes only validated PR/SHA values;
- only one automatic `main` dispatcher exists;
- iOS uses only manual and published-release triggers;
- no review workflow receives the production environment or deployment identity; and
- every external action is pinned to an immutable commit.

### Request and authorization contracts

Tests prove:

- malformed PR numbers and SHAs are rejected;
- unrelated or stale SHAs are rejected after a fresh PR-ref fetch;
- Git runs as `mixli-build`;
- the review SSH identity cannot invoke deploy, shell, sudo, or arbitrary commands;
- a newer SHA supersedes the previous unit safely; and
- duplicate requests for the same PR/SHA are idempotent.

### Rootless integration contracts

A live server validation proves:

- rootless daemon identity and exact data-root isolation;
- denial of rootful Docker, sudo, production secrets, production data, and published ports;
- complete required test-suite enumeration;
- Linux/web/Android and browser test execution;
- resource and timeout properties on the transient unit;
- preemption and cancellation cleanup; and
- zero leftover processes, sockets, data roots, worktrees, refs, images, networks, or volumes.

### Release regression contracts

Existing protected-main CI, image provenance, deployment rollback, firewall, backup/restore, Nginx, monitoring, and secret-boundary suites remain mandatory. Removing redundant GitHub dispatch must not remove the server release gate from deployment.

## Rollout

1. Commit workflow and server contract tests and capture expected server RED results.
2. Implement the review request boundary, rootless review runner, forced SSH command, and status reporter.
3. Validate the review lane with a non-main exact SHA and prove production remains unchanged.
4. Replace the GitHub workflow set and validate it statically.
5. Configure the review-only SSH key and GitHub App.
6. Run one real pull-request dispatch and verify the GitHub check lifecycle.
7. Run the protected-main gate before any production deployment.
8. Reconcile event-delivery application changes while retaining the new workflow set.

The workflow replacement and server review endpoint are activated together. The repository must not enter a state where expensive automatic workflows are removed but no approved pre-merge review path exists.

## Expected Cost Profile

Ordinary pull-request updates and `main` pushes consume only a short GitHub-hosted dispatcher job. All expensive Linux-capable work runs on the existing server. Paid macOS execution occurs only when explicitly requested or when a release is published.

## Security References

- GitHub secure-use guidance: <https://docs.github.com/en/actions/reference/security/secure-use>
- GitHub event semantics: <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>
- GitHub Actions repository settings: <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository>
