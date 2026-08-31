# Mobile Release Lane Design

**Date:** 2026-08-31
**Status:** Architecture approved in conversation; written specification pending review
**Branch:** `codex/low-cost-two-lane-ci`

This document supersedes only the Android-on-production-server requirements in `2026-08-29-low-cost-two-lane-ci-design.md`. Every other requirement in that design remains in force.

## Context

The protected server lane successfully validates the production infrastructure, API and PostgreSQL integration, Dart and Flutter packages, Chrome behavior, application tests, and the production web build. Android release assembly alone fails at the hardened container boundary when Gradle asks Java to launch the pinned CMake binary:

```text
Cannot run program "/opt/android-sdk/cmake/3.22.1/bin/cmake"
Exec failed, error: 13 (Permission denied)
```

Direct CMake and Java process-launch probes succeed, while the Gradle native-build path fails consistently. Weakening the production server's isolation to accommodate one mobile artifact would reduce reliability and security for the web/API deployment path.

## Goals

- Keep the production web/API deployment gate comprehensive, deterministic, and server-side.
- Prevent Android toolchain behavior from blocking web/API releases.
- Avoid paid GitHub builds on ordinary pushes and pull requests.
- Preserve an exact, reproducible Android release check when a mobile artifact is actually requested.
- Keep mobile release jobs separate from production credentials and deployment authority.

## Considered Approaches

### 1. Exceptional GitHub-hosted Android release lane — chosen

Run Android release assembly only for an explicit manual dispatch or a published GitHub release. This uses paid Linux capacity only when producing or validating a mobile release, requires no new server, and does not delay ordinary web/API delivery.

### 2. Dedicated self-hosted Android worker

Add a separate inexpensive Linux worker with the Android toolchain and no production authority. This removes the occasional GitHub build charge, but adds host cost, patching, monitoring, isolation, and recovery work. It remains the preferred future replacement if Android release frequency makes hosted execution materially expensive.

### 3. Weaken production container isolation — rejected

Run Android with broader privileges, relaxed process restrictions, or direct production-host tooling. This couples mobile build behavior to the production host and expands the blast radius of untrusted build inputs. It is incompatible with the reliability and security goals.

## Chosen Architecture

### Server web/API lane

The existing server runner remains authoritative for every Linux-capable production concern except Android artifact assembly. It continues to run:

- source-integrity and infrastructure contracts;
- API typechecking, unit tests, production image construction, migrations, and PostgreSQL integration;
- Dart formatting, Flutter analysis, package and application tests;
- real Chrome IndexedDB tests;
- platform declarations and permissions checks;
- the production Flutter web build; and
- exact API/PostgreSQL candidate-image retention and promotion for deployment.

The server lane must not invoke `flutter build apk`. Removing that command does not relax any web/API test, deployment, rollback, backup, monitoring, firewall, or image-provenance contract.

### Exceptional Android lane

A dedicated `android-release.yml` GitHub workflow runs only on:

- `workflow_dispatch`; or
- a published GitHub release.

The job checks out the selected manual ref or the immutable release tag, installs the repository-pinned Flutter version, resolves the lockfile with enforcement enabled, builds the release APK, verifies the expected artifact exists, and uploads it as a workflow artifact.

The workflow has read-only repository permissions. It receives no production environment, deployment SSH key, Cloudflare credential, database credential, object-storage credential, signing secret, or server access. The generated validation artifact is not evidence of production store signing; store signing and publication remain a separate explicit release concern.

### iOS lane

The existing iOS manual/published-release workflow remains unchanged. Android and iOS are exceptional mobile-release checks, while ordinary pull-request and `main` activity uses only the short dispatch workflows plus server execution.

## Trigger and Cost Contract

The authoritative automatic GitHub workflow set remains:

- `review-dispatch.yml` for short pull-request dispatch;
- `deploy-production.yml` for short protected-main deployment dispatch.

The only heavyweight GitHub-hosted workflows are `android-release.yml` and `ios-release.yml`, and neither may declare `push` or `pull_request` triggers. This keeps ordinary GitHub billing measured in dispatcher seconds rather than platform-build minutes.

## Failure Handling

- Android failure marks only the requested mobile-release workflow unsuccessful; it cannot stop or roll back a healthy web/API deployment.
- Web/API deployment remains fail-closed on any server-lane failure.
- A published release with a failed Android or iOS check is visibly incomplete and must not be treated as store-ready.
- Workflow artifacts use bounded retention and contain no credentials.
- A future dedicated worker must reproduce the same exact-ref, lockfile, toolchain, artifact, and least-privilege contracts before replacing the hosted lane.

## Verification

Repository contracts must prove:

- server CI no longer invokes or requires an APK build;
- server CI still performs the web release build and every existing non-Android stage;
- `android-release.yml` exists and has only manual and published-release triggers;
- the workflow uses the pinned Flutter version, lockfile enforcement, release APK build, artifact existence check, and artifact upload;
- the Android job has read-only permissions and no production environment or secrets; and
- the automatic heavyweight workflows removed by the low-cost two-lane design remain absent.

Live verification must then prove:

1. the complete server gate passes for an exact commit;
2. the exact API and PostgreSQL candidate images remain available for deployment;
3. the production deployment passes origin and public health checks; and
4. no CI rootless daemon, network, container, or temporary storage survives cleanup.

## Rollout

1. Add failing repository contracts for the new lane boundary.
2. Add the exceptional Android workflow and remove Android assembly from server CI.
3. Run focused workflow/server contracts on the server.
4. Run the complete exact-SHA server gate.
5. Install the validated server scripts and provisioned units.
6. Integrate the branch through protected `main`.
7. Deploy the exact protected-main SHA and verify `mixli.app` publicly and at the origin.
