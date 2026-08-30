# Mixli — Platform & Dependency Decisions

**Status:** Flutter architecture decision. Revalidate versions and licenses at adoption time.

## 1. Platform decision

Mixli's consumer application, shared Play renderer, and native creator surfaces use **Flutter + Dart**.

The reason is product-specific: Mixli depends on a continuously animated, media-heavy, gesture-heavy Play surface with custom drawing, precise interaction feedback, and a shared rendering model across iOS, Android, and web.

Flutter's current Impeller renderer is the default on iOS and modern Android and is designed for predictable shader/rendering behavior. Performance is still an engineering responsibility: the product must profile real devices and hold explicit frame/memory/media budgets.

Do not describe Flutter as universally faster than every alternative. It is the selected architecture because it fits Mixli's interaction/runtime requirements and gives the team a single high-control rendering stack.

## 2. Selection rules

A dependency belongs in Mixli only when it materially improves one of:

- frame/feed performance;
- Play expressiveness;
- creator speed;
- media reliability;
- sharing/growth;
- ranking/experimentation;
- trust/operability.

Prefer:

- actively maintained projects;
- permissive commercial-use licensing;
- strong Flutter/Dart support;
- first-party Flutter packages where they meet the requirement;
- narrow abstractions around strategically risky dependencies;
- boring infrastructure over bespoke reinvention.

Do not install the whole shortlist at bootstrap.

## 3. Approved / preferred shortlist

| Area | Project | Decision | Stage | Mixli use |
|---|---|---|---|---|
| App/runtime | [flutter/flutter](https://github.com/flutter/flutter) | Adopt | M0 | iOS/Android/web UI and Play rendering |
| State | [rrousselGit/riverpod](https://github.com/rrousselGit/riverpod) | Adopt | M0 | explicit app/service state and async orchestration |
| Routing | [flutter/packages — go_router](https://github.com/flutter/packages/tree/main/packages/go_router) | Adopt | M0 | canonical routes, shared Play URLs, deep-link-aware navigation |
| Video | [flutter/packages — video_player](https://github.com/flutter/packages/tree/main/packages/video_player/video_player) | Adopt first | M1 | short Play clips; replace only if measured requirements exceed it |
| Camera | [flutter/packages — camera](https://github.com/flutter/packages/tree/main/packages/camera/camera) | Adopt first | M5 | creator image/video capture |
| Interactive audio | [alnitak/flutter_soloud](https://github.com/alnitak/flutter_soloud) | Adopt behind abstraction | M1/M4 | low-latency piano, rhythm, scheduled sound |
| Persistence | [simolus3/drift](https://github.com/simolus3/drift) | Adopt when local model needs it | M2 | feed window, actor state, drafts, upload state, offline metadata |
| Immutable models | [rrousselGit/freezed](https://github.com/rrousselGit/freezed) | Optional | M1+ | complex union/data classes if native Dart records/sealed types become noisy |
| Images | [Baseflow/flutter_cached_network_image](https://github.com/Baseflow/flutter_cached_network_image) | Evaluate | M2 | disk-backed image caching on native; Flutter built-ins remain baseline |
| Sharing | [fluttercommunity/plus_plugins — share_plus](https://github.com/fluttercommunity/plus_plugins/tree/main/packages/share_plus/share_plus) | Adopt | M3 | platform share UI |
| Connectivity | [fluttercommunity/plus_plugins — connectivity_plus](https://github.com/fluttercommunity/plus_plugins/tree/main/packages/connectivity_plus/connectivity_plus) | Adopt only if useful | M2/M5 | network hints; never treat connectivity status as proof internet works |
| App/universal links | [llfbandit/app_links](https://github.com/llfbandit/app_links) | Evaluate | M3 | incoming HTTPS/custom-scheme links if go_router/platform handling is insufficient |
| Resumable upload | tus protocol; [jjmutumi/tus_client](https://github.com/jjmutumi/tus_client) / maintained alternative | Protocol required, client re-evaluate | M5 | resumable creator media upload |
| Similarity | [pgvector/pgvector](https://github.com/pgvector/pgvector) | Adopt when semantic similarity is required | M6/M7 | adjacency, duplicate detection, semantic search |
| Experiments/flags | [growthbook/growthbook-flutter](https://github.com/growthbook/growthbook-flutter) | Preferred; license/deployment review | M2 | experiments, remote config, kill switches |
| Crash/performance | [getsentry/sentry-dart](https://github.com/getsentry/sentry-dart) | Adopt | M0 | Flutter/native crashes and traces |
| OTA Dart patches | [shorebirdtech/shorebird](https://github.com/shorebirdtech/shorebird) | Evaluate after beta | Operations | controlled patching; not required for first tranche |

Server/creator-web dependencies such as PostgreSQL, pgvector, FFmpeg-class media processing, and web admin tooling remain independent of the Flutter client decision.

## 4. Core bootstrap set

Preferred first implementation set:

```text
Flutter / Dart
Riverpod
go_router
Sentry Flutter
```

The Play schema/engine packages should remain pure Dart where Flutter UI APIs are unnecessary.

Add `video_player` with the first clip Play and `flutter_soloud` with the first timing-sensitive audio Play.

Do not add local SQL, camera, uploads, feature flags, or semantic search before their milestones require them.

## 5. Rendering architecture

Split domain execution from rendering:

```text
Play JSON
   ↓
play_schema       # pure Dart validation/model
   ↓
play_engine       # pure Dart deterministic state machine
   ↓
play_flutter      # Flutter primitive renderers
   ↓
mobile / web
```

The engine must not depend on widgets, BuildContext, platform channels, or Flutter lifecycle APIs.

This enables:

- deterministic unit tests;
- schema compatibility tests;
- native/web semantic parity;
- headless validation;
- later alternate renderers without changing authored Plays.

## 6. Flutter performance rules

### Frame budget

Target:

- 60 Hz: frame work stays within ~16 ms;
- 120 Hz: target ~8 ms where device/app path supports it;
- no normal feed swipe lands on a spinner;
- no Play may monopolize raster/UI work after leaving the viewport.

### Build/layout

- keep rebuild scope local;
- prefer `const` widgets where valid;
- use lazy `PageView`/list construction;
- avoid intrinsic layout on feed-critical paths;
- avoid unnecessary opacity, clipping, backdrop filters, and saveLayer-heavy effects;
- release video/audio/custom-painter resources promptly when a Play leaves the active window.

### Content-first design

The visual design must not spend GPU budget on decorative blur, clipping, shadows, or shaders that compete with the actual media/interaction.

See [`visual-language-and-copy-spec.md`](visual-language-and-copy-spec.md).

## 7. Abstraction boundaries

### Audio

Application/runtime code depends on Mixli `AudioEngine`, not directly on `flutter_soloud`.

Contract must support:

```text
load
play
schedule
stop
release
latencyMetrics
```

Reason: timing-sensitive audio is strategically important and must remain replaceable/testable.

### Video

Play runtime depends on `VideoSurface`/controller adapter, not `video_player` types in schema/domain code.

### Upload

Creator code depends on `UploadSession`:

```text
create
resume
pause
cancel
progress
complete
```

The tus protocol is a transport decision, not the creator domain model.

### Feature flags

Application code uses Mixli-owned flag keys/config interface.

Do not scatter GrowthBook-specific APIs throughout product code.

### Deep links

Canonical Mixli HTTPS URLs are product infrastructure.

Use an adapter for provider-specific attribution/deferred-linking systems. Removing a vendor must never break canonical Play URLs.

### Analytics

Mixli owns the canonical event envelope and durable event stream.

Sentry, GrowthBook, PostHog, or another vendor may receive derived events, but ranking cannot depend on vendor-specific storage semantics.

### Similarity

Ranking/search uses a Mixli similarity interface; first backend may be pgvector inside PostgreSQL.

## 8. Package-specific notes

### Riverpod

Use for app/service state and async dependencies, not to hide the deterministic Play engine inside UI providers.

Play session state should be a clear domain object with Riverpod only adapting it to widgets.

### go_router

Canonical routes should include public Play URLs from inception.

Route/deep-link behavior must be covered by tests because sharing is a core growth loop.

### video_player

Use first-party implementation until measurements prove missing requirements. Preload only the bounded next media window.

### flutter_soloud

Before production scoring:

- measure device latency;
- test Bluetooth routes;
- test interruptions/audio focus;
- test sample/scheduling precision;
- test low-end Android;
- define tolerance bands for rhythm/piano evaluation.

### Drift

Use only when local state becomes relational or transactional enough to justify it. Do not put transient per-frame interaction state in SQLite.

### Camera

Start with Flutter's first-party camera plugin. Add a more specialized native capture stack only if creator workflows require capabilities it cannot provide.

### tus

Resumability is required; the specific Dart client is not locked yet because the ecosystem is smaller than the web tus ecosystem. Wrap the client and maintain protocol-level integration tests.

### GrowthBook Flutter

Use through a Mixli flag interface. Verify current SDK/repository licensing and deployment requirements before adoption.

### Sentry

Instrument:

- feed request;
- Play decode/validation;
- Play mount/resolve;
- first media frame;
- audio readiness;
- share-route resolution;
- creator upload/publish.

Do not send authored/user-sensitive payloads in breadcrumbs by default.

## 9. Web architecture

The shared Play surface may be rendered by Flutter web so the same Play semantics and visual primitives are reused.

Social preview metadata still needs server/edge-generated HTML metadata before the Flutter bundle boots.

Therefore:

```text
request /p/:id
   ↓
server/edge shell supplies OG metadata
   ↓
Flutter web boots
   ↓
Play schema + engine executes
```

Do not leak quiz answers in OG metadata.

## 10. Explicit non-decisions

Do not introduce yet:

- separate graph database;
- separate vector database;
- Kafka/Pulsar-scale event infrastructure;
- Kubernetes solely for architectural fashion;
- generic game engine;
- arbitrary creator plugins/code;
- full video-editor SDK;
- heavyweight local architecture framework on top of Flutter/Riverpod;
- custom rendering engine where Flutter/CustomPainter/Impeller is sufficient.

## 11. License/security gate

Before production adoption:

- inspect current upstream license and subdirectory exceptions;
- review maintenance/release activity;
- review security advisories;
- pin versions in `pubspec.lock` for applications;
- record native platform implications;
- add notices when required;
- include in SBOM/dependency inventory;
- identify owner for strategic/native dependencies.

## 12. Upgrade policy

- pure Dart dependencies: small frequent updates;
- Flutter SDK/native plugins: planned compatibility tranche with representative device profiling;
- schema/engine-critical dependencies: compatibility fixtures before merge;
- security patches: expedited path with staged rollout/rollback where practical.

## 13. Decision test

A dependency is justified only if removing it would force Mixli to rebuild substantial non-differentiating infrastructure or materially worsen the Play/creator experience.
