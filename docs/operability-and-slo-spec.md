# Mosaic — Operability & SLO Specification

## 1. Purpose

A swipe-first product fails quickly if media stalls, Plays crash, creator uploads disappear, or a bad ranking/primitive cannot be disabled remotely.

Operability is part of the product contract.

## 2. Observability baseline

Every production surface must emit:

- structured logs;
- metrics;
- traces/spans for critical paths;
- crash/error reports;
- release/build identifiers;
- feature/experiment configuration version.

Recommended client crash/performance tooling: Sentry React Native.

## 3. Critical paths

Instrument at minimum:

```text
feed_request
candidate_generation
ranking
play_schema_fetch
play_schema_parse
play_renderer_mount
media_request
media_first_frame
audio_ready
play_action
swipe_transition
share_link_resolve
web_play_render
creator_upload
media_processing
publish_validation
moderation_action
```

## 4. Initial service objectives

These are launch targets and should be tightened from observed production data.

### API availability

- core feed/read APIs: 99.9% monthly availability target;
- publication/moderation write paths: 99.9% monthly availability target.

### API latency

Excluding third-party media delivery:

- feed API p95 ≤ 300 ms at normal load;
- Play metadata/schema API p95 ≤ 250 ms;
- save/hide/mute acknowledgment p95 ≤ 300 ms;
- share-link resolution p95 ≤ 250 ms.

### Client health

- crash-free sessions ≥ 99.8% controlled beta target;
- renderer/runtime fatal-error rate < 0.1% of Play starts;
- malformed published Play rate: 0 by publication contract.

Targets are measured by supported platform/build and not hidden inside one global average.

## 5. Experience budgets

Measure separately by network tier and device class.

Required metrics:

- app open → first usable feed shell;
- swipe → next Play shell visible;
- Play visible → primary media ready;
- video request → first frame;
- tap-to-hear → audio-ready latency;
- creator capture → editable draft;
- publish request → published/clear pending state.

The feed shell and prompt must not wait for heavy media when the Play can be understood before it arrives.

## 6. Audio-specific budgets

Music/rhythm interactions require their own instrumentation:

- output scheduling latency;
- input timestamp precision;
- Bluetooth route state;
- interruption/focus changes;
- playback underrun;
- round-trip timing tolerance where relevant.

Scoring tolerances must account for known platform/device latency and must not punish users for transport delay.

## 7. Feature flags and kill switches

Remote configuration must be able to disable or change without a client release:

- runtime primitive;
- template;
- Play revision;
- creator distribution;
- recommendation bucket/weight set;
- experiment;
- sharing;
- creator capture path;
- audio feature;
- media derivative/profile.

Every risky rollout should have a named rollback flag before release.

GrowthBook is a preferred candidate for feature flags/experimentation, subject to license/deployment review.

## 8. Release strategy

Use staged rollout:

```text
internal
→ staff/seed creators
→ small beta cohort
→ larger beta
→ broad release
```

For changes to runtime schema/primitives:

- compatibility fixture tests pass;
- old supported Play revisions still render;
- new primitive can be remotely disabled;
- server does not send unsupported schema versions to old clients.

## 9. Incident classes

### P0

Safety/privacy breach, widespread account compromise, or harmful content distribution that cannot be contained normally.

### P1

Core feed unusable, publication corruption, widespread crashes, broken share links, or severe media outage.

### P2

Material degradation of one format/primitive, ranking regression, creator upload failure, or elevated error rate.

### P3

Localized bug with workaround and limited impact.

Each P0/P1 requires an incident record and follow-up action list.

## 10. Ranking observability

For sampled requests retain enough trace to answer:

- which candidates were considered;
- source bucket;
- ranking/config version;
- major feature contributions;
- exclusions;
- final order;
- resulting actions.

A ranking regression must be debuggable without reconstructing state from dashboards manually.

## 11. Event reliability

Analytics/recommendation events are asynchronous but must have:

- versioned envelope;
- local buffering where practical;
- idempotency/deduplication identifiers;
- bounded retry;
- server ingestion validation;
- dead-letter/error visibility.

Loss of analytics must not block Play interaction, but prolonged event loss should page/alert because ranking quality depends on it.

## 12. Data protection

- secrets never appear in logs;
- redact tokens and sensitive request fields;
- access to moderation/identity logs is role-limited;
- production debugging should use actor/session IDs, not raw personal data where avoidable;
- retention is explicit by log/event class.

## 13. Backups and recovery

System-of-record PostgreSQL requires:

- automated backups;
- point-in-time recovery where supported;
- periodic restore drills;
- migration rollback/forward-repair procedure.

Object storage requires versioning/retention appropriate to accidental deletion and moderation/takedown requirements.

Published Play revisions and lineage must be recoverable independently of caches.

## 14. Dependency hygiene

- lockfile committed;
- dependency updates reviewed continuously;
- automated vulnerability scanning;
- SBOM generated for releases where practical;
- licenses checked before adoption;
- critical runtime dependencies pinned through normal semver/lockfile policy, not GitHub branches;
- native dependency upgrades tested on representative devices.

## 15. Capacity controls

Protect services with:

- per-user/IP creation/report/share limits;
- upload concurrency/size limits;
- feed request throttling under abuse;
- media-processing queue backpressure;
- bounded candidate-set sizes;
- bounded Play graph/resource limits.

Degrade optional work before core Play/feed availability.

## 16. Launch dashboard

One launch dashboard should show at minimum:

- active sessions;
- feed API p50/p95/p99;
- Play start/completion/dismiss;
- media first-frame/audio-ready failures;
- crash-free sessions;
- share-link opens/completions;
- upload success/resume/failure;
- publish validation failures;
- reports/moderation queue;
- current experiment/flag versions.

## 17. Launch gate

Controlled beta requires:

- crash/error reporting;
- core traces/metrics;
- remote kill switches;
- staged rollout;
- backup/restore procedure;
- incident ownership;
- dependency/security scanning;
- dashboards for feed, runtime, media, creator, and sharing paths.
