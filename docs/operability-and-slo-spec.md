# Mixli — Operability & SLO Specification

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

Recommended client crash/performance tooling: Sentry Flutter.

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

Flutter client telemetry also records frame build/raster timing, jank clusters, active Play type, and device refresh rate without attaching authored/user-sensitive payloads.

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

Measure separately by network tier, refresh rate, and device class.

Required metrics:

- app open → first usable feed shell;
- swipe → next Play shell visible;
- Play visible → primary media ready;
- video request → first frame;
- tap-to-hear → audio-ready latency;
- frame build/raster duration;
- janky frames per Play/session;
- creator capture → editable draft;
- publish request → published/clear pending state.

The feed shell and prompt must not wait for heavy media when the Play can be understood before it arrives.

### Frame targets

- 60 Hz devices: keep normal frame work inside ~16 ms;
- 120 Hz-class paths: target ~8 ms where the device/platform supports it;
- diagnose build and raster time separately;
- performance regressions are reviewed by Play primitive and device class.

The target is experienced smoothness, not a global average that hides bad devices or primitives.

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

GrowthBook Flutter is a preferred candidate for feature flags/experimentation, subject to license/deployment review and isolated behind Mixli's flag interface.

### Failure defaults

- config service unavailable → last-known-good config, then compiled safe defaults;
- ranking unavailable → bounded curated fallback feed;
- analytics unavailable → interaction continues with bounded local spool;
- attribution provider unavailable → canonical Play URL still resolves;
- moderation confidence unavailable → new/questionable UGC does not gain broad distribution.

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
- client/server capability negotiation is tested;
- new primitive can be remotely disabled;
- server does not send unsupported schema/required primitives to old clients.

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
- globally/idempotently unique client event ID;
- actor/session IDs;
- client observed timestamp;
- server receive timestamp;
- local buffering where practical;
- bounded retry;
- server ingestion validation/deduplication;
- dead-letter/error visibility.

Do not use client wall-clock time for security/integrity ordering. Local spool is bounded by count/bytes/age and discards low-value telemetry before product-critical pending actions.

Loss of analytics must not block Play interaction, but prolonged event loss should alert because ranking quality depends on it.

## 12. Process-death recovery

Treat ungraceful mobile process death as normal.

Recover only durable product state:

- anonymous actor identity;
- onboarding/interests/learning intent;
- bounded feed cursor/window metadata;
- creator drafts and local asset/upload session references;
- bounded unsent event spool;
- pending optimistic mutations that can be replayed idempotently.

Do not persist widget trees or native media-controller state.

## 13. Data protection

- secrets never appear in logs;
- redact tokens and sensitive request fields;
- access to moderation/identity logs is role-limited;
- production debugging should use actor/session IDs, not raw personal data where avoidable;
- retention is explicit by log/event class.

## 14. Store/privacy release engineering

Every release train must verify:

- iOS `PrivacyInfo.xcprivacy` is present/valid where required;
- required-reason API declarations match the built app and third-party SDKs;
- third-party SDK privacy/signature requirements are reviewed;
- App Store privacy labels match actual data collection/use;
- Google Play Data Safety declarations match actual collection/use;
- privacy policy, retention/deletion, and account deletion routes are current;
- permission-purpose strings match actual contextual permission flows.

Adding/upgrading a native SDK is a privacy/release review event, not only a dependency change.

## 15. Backups and recovery

System-of-record PostgreSQL requires:

- automated backups;
- point-in-time recovery where supported;
- periodic restore drills;
- migration rollback/forward-repair procedure.

Object storage requires versioning/retention appropriate to accidental deletion and moderation/takedown requirements.

Published Play revisions and lineage must be recoverable independently of caches.

## 16. Dependency hygiene

- lockfiles committed;
- dependency updates reviewed continuously;
- automated vulnerability scanning;
- SBOM generated for releases where practical;
- licenses checked before adoption;
- privacy/permission impact checked for native SDK changes;
- critical runtime dependencies pinned through normal semver/lockfile policy, not GitHub branches;
- Flutter SDK/native plugin upgrades tested on representative devices.

## 17. Capacity and memory controls

Protect services with:

- per-user/IP creation/report/share limits;
- upload concurrency/size limits;
- feed request throttling under abuse;
- media-processing queue backpressure;
- bounded candidate-set sizes;
- bounded Play graph/resource limits.

Client budgets are separately bounded for Play schemas, images, video/audio buffers, custom-render resources, creator local media, and event spool. On memory pressure, release speculative/prefetched resources before current Play state.

Degrade optional work before core Play/feed availability.

## 18. Physical-device release matrix

Before controlled beta smoke-test at minimum:

- current iPhone;
- older supported iPhone;
- flagship Android;
- lower/mid-range Android;
- at least one 120 Hz device;
- Bluetooth audio route;
- Safari/Chrome mobile web.

Cover feed jank/memory growth, media first frame, lifecycle suspend/resume, audio timing, process recovery, permission flows, and shared Play behavior.

## 19. Launch dashboard

One launch dashboard should show at minimum:

- active sessions;
- feed API p50/p95/p99;
- Play start/completion/dismiss;
- media first-frame/audio-ready failures;
- frame/jank distribution by device/Play primitive;
- crash-free sessions;
- share-link opens/completions;
- upload success/resume/failure;
- publish validation failures;
- reports/moderation queue;
- current experiment/flag versions.

## 20. Launch gate

Controlled beta requires:

- strict locked Flutter CI green;
- crash/error reporting;
- frame/runtime/media telemetry;
- core traces/metrics;
- bounded offline event spool + idempotent ingestion;
- process-death recovery for anonymous state/creator drafts;
- schema/client capability negotiation;
- remote kill switches and safe fallback behavior;
- staged rollout;
- backup/restore procedure;
- incident ownership;
- dependency/security/privacy scanning;
- App Store/Play Store privacy/compliance checklist;
- physical-device smoke matrix;
- dashboards for feed, runtime, media, creator, and sharing paths.
