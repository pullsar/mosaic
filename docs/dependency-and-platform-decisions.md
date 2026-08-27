# Mosaic — Platform & Dependency Decisions

**Status:** initial architecture decision record. Revalidate versions/licenses at adoption time.

## 1. Selection rules

A dependency belongs in Mosaic only when it materially improves one of:

- feed performance;
- Play expressiveness;
- creator speed;
- sharing/growth;
- ranking/experimentation;
- trust/operability.

Prefer:

- actively maintained projects;
- permissive commercial-use licensing;
- strong React Native/New Architecture support where relevant;
- narrow abstractions around strategically risky dependencies;
- boring infrastructure over bespoke reinvention.

Do not install the whole shortlist at repository bootstrap.

## 2. Approved / preferred shortlist

| Area | Project | Decision | Stage | Mosaic use |
|---|---|---|---|---|
| App foundation | [expo/expo](https://github.com/expo/expo) | Adopt | M0 | iOS/Android/web foundation, routing/device APIs |
| Gestures | [software-mansion/react-native-gesture-handler](https://github.com/software-mansion/react-native-gesture-handler) | Adopt | M0/M1 | feed swipe + nested manipulation |
| Animation | [software-mansion/react-native-reanimated](https://github.com/software-mansion/react-native-reanimated) | Adopt | M0/M1 | UI-thread interaction/animation |
| Feed | [Shopify/flash-list](https://github.com/Shopify/flash-list) | Adopt | M1/M2 | heterogeneous performant Play feed |
| Schema | [colinhacks/zod](https://github.com/colinhacks/zod) | Adopt | M0 | Play/event/API runtime validation |
| Server state | [TanStack/query](https://github.com/TanStack/query) | Adopt | M1/M2 | feed/cache/retry/offline-aware server state |
| Graphics | [Shopify/react-native-skia](https://github.com/Shopify/react-native-skia) | Adopt when primitive needs it | M1/M3 | puzzles, drawing, hotspots, visual mini-games |
| Interactive audio | [software-mansion/react-native-audio-api](https://github.com/software-mansion/react-native-audio-api) | Adopt behind abstraction | M1/M3 | piano, rhythm, tone scheduling |
| Camera capture | [mrousavy/react-native-vision-camera](https://github.com/mrousavy/react-native-vision-camera) | Evaluate/adopt when Expo capture is insufficient | M4+ | creator photo/video capture |
| Web uploads | [transloadit/uppy](https://github.com/transloadit/uppy) | Adopt | M4 | resilient creator-web uploads |
| Resumable upload | [tus/tus-js-client](https://github.com/tus/tus-js-client) | Adopt/protocol baseline | M4 | resumable web/native upload |
| Studio graph UI | [xyflow/xyflow](https://github.com/xyflow/xyflow) | Adopt later | M7 | power-creator state graph editor |
| Similarity | [pgvector/pgvector](https://github.com/pgvector/pgvector) | Adopt when semantic similarity is required | M5/M6 | adjacency, duplicate detection, semantic search |
| Experiments/flags | [growthbook/growthbook](https://github.com/growthbook/growthbook) | Preferred; deployment/license review required | M2 | experiments, remote config, kill switches |
| Crash/performance | [getsentry/sentry-react-native](https://github.com/getsentry/sentry-react-native) | Adopt | M0/M1 | native/JS crashes and performance telemetry |
| Product analytics UI | [PostHog/posthog-js](https://github.com/PostHog/posthog-js) | Optional | M2 | product exploration; not event source of truth |
| Native sharing | [react-native-share/react-native-share](https://github.com/react-native-share/react-native-share) | Adopt if Expo/system share is insufficient | M2/M3 | share sheet/direct share targets |
| Deferred deep links | [BranchMetrics/react-native-branch-deep-linking-attribution](https://github.com/BranchMetrics/react-native-branch-deep-linking-attribution) | Provider option, not core dependency | Growth | attribution/deferred deep linking |

## 3. Core bootstrap set

Do not begin with all dependencies.

Preferred first implementation set:

```text
Expo
React Native Gesture Handler
React Native Reanimated
FlashList
Zod
TanStack Query
Sentry React Native
```

Add Skia and React Native Audio API only with their first real Play primitive.

## 4. Abstraction boundaries

### Audio

Application code depends on Mosaic `AudioEngine`, not directly on React Native Audio API.

Reason: interactive audio is strategically important and the underlying library is younger than the basic UI stack.

### Upload

Creator code depends on `UploadSession` contract:

```text
create
resume
pause
cancel
progress
complete
```

Uppy/tus are implementations, not the domain model.

### Feature flags

Application code uses Mosaic flag keys/config client.

Avoid scattering GrowthBook-specific semantics throughout runtime/ranking code.

### Deep links

Use a `DeepLinkProvider` interface.

Canonical Mosaic URLs must continue working if Branch or another attribution provider is removed.

### Analytics

Mosaic owns the canonical event envelope and durable event stream.

PostHog/Sentry/other vendors receive derived or forwarded events; recommendation logic must not depend on vendor-specific event storage.

### Similarity

Ranking/search code depends on a similarity interface. Initial implementation may use pgvector inside PostgreSQL without introducing a standalone vector database.

## 5. Dependency-specific notes

### Expo

Use one universal application foundation where practical, including the lightweight web Play surface. Native-only capabilities remain isolated behind platform adapters.

### FlashList

Treat Play rows as heterogeneous types. Ensure recycling does not retain audio/canvas/video state between different Play revisions.

### Skia

Do not make every Play a canvas. Use native/basic components for simple Choice/Guess UI; Skia is for interactions that materially benefit from custom graphics.

### React Native Audio API

Required engineering tests before production music/rhythm scoring:

- device latency;
- Bluetooth;
- interruption/audio focus;
- scheduling precision;
- low-end Android behavior.

### VisionCamera

Do not replace simple platform capture with a complex camera surface until creator workflows require advanced capture/frame processing.

### Uppy/tus

Resumability is the requirement. Creator drafts and upload session identifiers must survive navigation/restart where supported.

### XYFlow

Power-creator Studio only. Quick Create and Remix must remain form/template driven.

### pgvector

Use inside the existing PostgreSQL architecture first. Candidate use cases:

- semantic duplicate detection;
- related-topic/Play retrieval;
- wildcard discovery;
- search;
- Demand Board clustering.

Its repository license is PostgreSQL-style permissive; retain required notices.

### GrowthBook

The repository uses MIT for core content with enterprise-licensed directories. Only use components whose license/deployment terms are explicitly reviewed. Mosaic should remain operable if the provider is changed.

### Sentry

Instrument Play runtime and media paths with custom spans; avoid uploading sensitive creator/user payloads in breadcrumbs or errors.

## 6. Explicit non-decisions

Do not introduce yet:

- separate graph database;
- separate vector database;
- Kafka/Pulsar-scale event infrastructure;
- Kubernetes solely for architectural fashion;
- arbitrary plugin execution;
- generic game engine inside the app;
- full video-editor SDK;
- heavy domain ORM.

These require concrete scale/product evidence.

## 7. License/security gate

Before adding any dependency to production:

- inspect current upstream license, including subdirectory/enterprise exceptions;
- check maintenance/release activity;
- review known security advisories;
- pin through package manager/lockfile;
- record native platform implications;
- add license notice if required;
- add to SBOM/dependency inventory;
- define an owner for strategic/native dependencies.

## 8. Upgrade policy

- routine JS dependencies: small frequent updates;
- React Native/Expo/native stack: planned compatibility tranche with representative device testing;
- schema/runtime-critical dependencies: compatibility fixtures before merge;
- security patch: expedited path with rollout/rollback flag where possible.

## 9. Decision test

A dependency is justified only if removing it would require Mosaic to rebuild substantial, non-differentiating infrastructure or materially worsen the Play/creator experience.
