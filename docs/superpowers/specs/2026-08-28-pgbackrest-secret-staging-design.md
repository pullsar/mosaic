# pgBackRest Root-Only Secret Staging Design

## Context

The production pgBackRest configuration contains the R2 access key, secret key, and repository cipher passphrase. The host copy must remain readable only by root. Making it group-readable by the PostgreSQL container's numeric group is unsafe because container IDs can map to unrelated privileged host groups; on this host, GID 999 maps to `systemd-journal`.

Production is currently disabled, so the host configuration has been contained at `root:root 0600` while this startup path is implemented.

## Decision

Keep `/etc/mixli/postgres/pgbackrest.conf` as `root:root 0600` and mount it read-only into the PostgreSQL container at a root-only staging path such as `/run/mixli-secrets/pgbackrest.conf`. A small container entrypoint wrapper will:

1. start as root;
2. require the staged file to be a regular, non-empty file;
3. copy it atomically to container-private `/etc/pgbackrest/pgbackrest.conf`;
4. set `postgres:postgres 0600` on the private copy;
5. validate that required repository and stanza keys are present without logging values;
6. execute the upstream PostgreSQL entrypoint unchanged.

The mounted host file is never made readable to a non-root host UID or GID. The private copy disappears with the container and is recreated on every start, including reboots and release rollbacks.

## Alternatives Rejected

- **Host supplemental group:** rejected because it couples host and container numeric IDs and can silently grant access to an unrelated host principal.
- **World-readable configuration:** rejected because it exposes long-lived backup and repository-encryption credentials.
- **Environment-variable injection:** rejected because pgBackRest still needs a coherent configuration for PostgreSQL startup, WAL archiving, backup jobs, and isolated restores; duplicating secret values across process environments increases leakage and drift risk.

## Components and Data Flow

- The host provisioner creates the root-only staging directory and validates ownership and mode.
- Compose mounts the host configuration at the staging path, never directly over the runtime pgBackRest path.
- The PostgreSQL image contains the wrapper and the checked-in non-secret example configuration.
- The wrapper creates the runtime configuration before handing control to the official image entrypoint.
- `deployment.sh`, scheduled backups, production verification, and restore verification continue using the normal in-container pgBackRest path and require no secret-aware branching.

## Failure Behavior

The container exits before PostgreSQL starts when the staged file is missing, empty, not a regular file, cannot be copied, has an unexpected owner/mode on the host, or lacks required configuration keys. Validation messages name only the failed invariant; they never print configuration lines or values. Docker restart policy may retry, while monitoring reports PostgreSQL and backup unavailability.

An existing running container is not modified in place. A configuration rotation is activated by recreating PostgreSQL during an approved deployment or maintenance operation, after the new R2 credential passes a disposable write/read/delete check.

## Verification

Server CI will prove:

- Compose mounts the host file only at the root-only staging path;
- the wrapper fails when the staged file is absent or invalid;
- the wrapper produces a `postgres:postgres 0600` private copy without changing the host file;
- the wrapper delegates arguments and exit status to the upstream entrypoint;
- built-image integration can create a stanza and complete a local pgBackRest backup;
- no configuration values appear in test output.

Before production enablement, the server will additionally verify host ownership/mode, recreate the PostgreSQL container, run `pgbackrest check` for both repositories, complete a full backup, and perform the documented isolated restore test.

## Scope

This change only fixes pgBackRest secret delivery. Media-worker credentials remain separate, and production media workers are not enabled until their retry/dead-letter, image tooling, observability, and private media-bucket design is implemented.
