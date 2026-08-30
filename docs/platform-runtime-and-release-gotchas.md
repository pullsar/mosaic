# Mixli — Platform Runtime & Release Gotchas

This document turns platform-specific failure modes into implementation requirements. It supplements the implementation, media, trust, operability, and experience specs.

## 1. Flutter web is not a normal HTML page

Shared Plays need both a Flutter runtime and a conventional server/edge HTML shell.

Requirements:

- server/edge response owns title, canonical URL, Open Graph/Twitter metadata, robots policy, and no-answer-leak previews;
- Flutter boots inside that shell for the interactive Play;
- shared Play links must remain useful before Flutter initialization completes;
- unsupported Flutter/web primitives fail explicitly or use a declared fallback;
- do not depend on Flutter canvas rendering for social metadata or crawler-visible metadata.

Flutter web accessibility semantics must be enabled intentionally. The web bootstrap should call the supported semantics-enabling path and every custom Play primitive must expose meaningful `Semantics` roles/order.

## 2. Browser media capability is variable

Do not assume identical video/audio behavior across Safari, Chrome, Android WebView, iOS, or desktop browsers.

Rules:

- no Play depends on audible autoplay;
- short clips may start muted only when browser policy permits;
- `Hear`/tap-to-play remains the reliable audio path;
- maintain a tested browser/device playback matrix;
- server media negotiation chooses a compatible derivative;
- web fallback remains playable if one codec/profile is unavailable.

## 3. Normalize creator media aggressively

Modern phones can capture HEVC, HDR, variable frame rate, unusual color spaces, and very large media.

For launch, published video should always have a broadly compatible SDR derivative. Preferred baseline is MP4/H.264 video with AAC audio, plus additional derivatives only where measured value justifies them.

Processing must handle:

- HEVC/H.265 source;
- HDR source → safe SDR fallback;
- variable frame rate;
- rotation/orientation metadata;
- wide-gamut color;
- silent clips;
- audio channel/sample-rate normalization;
- poster frame generation.

Do not use HEVC/HDR as the only published derivative.

## 4. One visible Play owns active media

The feed must have a single active-media owner.

When a Play loses visibility, route focus, or application focus:

- stop/pause video;
- stop/pause non-background audio;
- cancel timers that should not continue;
- release heavy decoders/resources outside the bounded warm window;
- preserve semantic Play state separately from media-controller state.

On resume, restore from Play state; never assume a native media controller survived suspension.

## 5. Process death is normal

Mobile OSes can kill Mixli without a graceful shutdown.

Persist only the state needed to recover value:

- anonymous actor identity;
- onboarding/interests/learning intent;
- bounded feed cursor/window metadata;
- unsent analytics/event spool;
- creator drafts;
- local creator asset records/upload session IDs;
- pending saves/hides where optimistic UX is used.

Recovery must be idempotent. Do not persist arbitrary widget trees or media-controller state.

## 6. Background upload is best-effort, not a promise

A resumable upload does not imply an upload will continue indefinitely while the app is suspended.

Requirements:

- creator work is safe before upload begins;
- upload can pause when the OS suspends the app;
- resumable session continues after foregrounding/relaunch;
- user sees honest state (`Uploading`, `Paused`, `Retry`), not fake continuous progress;
- background execution is introduced only with platform-native support and a demonstrated creator need.

## 7. Request the least permission possible

Permissions are contextual, not onboarding steps.

- use Android system Photo Picker / platform pickers instead of broad storage access;
- request camera only when the user chooses capture;
- request microphone only when a Play/creator action requires recording;
- do not request location in v1 unless a future explicit location primitive is approved;
- notification permission is requested only after a clear user-valued reason exists;
- denial always has a graceful path.

## 8. UGC store-policy requirements are product requirements

Before a user can publish community-visible content:

- accept concise Terms / creator rules;
- prohibited content is clearly defined;
- report content and creator/user flows exist;
- block creator/user exists, not only recommendation mute;
- moderation can suspend distribution immediately;
- support/privacy/contact routes are accessible in-app;
- account/data deletion paths are functional.

`Mute` is a recommendation preference. `Block` is a safety/social boundary. Keep them distinct.

## 9. Privacy/release metadata must ship with the app

Release engineering must maintain:

- iOS `PrivacyInfo.xcprivacy` and required-reason API declarations;
- third-party SDK privacy-manifest/signature review;
- App Store privacy labels;
- Google Play Data Safety declarations;
- in-app privacy policy link;
- retention/deletion disclosure;
- permission-purpose strings generated/tested per platform.

Adding an SDK is therefore both an engineering and privacy-schema change.

## 10. Canonical deep links are Mixli-owned

Canonical public Play URLs must not depend on Branch or another attribution provider.

Test:

- installed app → Play;
- not installed → browser Play;
- stale/removed Play → safe unavailable state;
- unsupported primitive → safe fallback;
- challenge context cannot change immutable Play content;
- attribution failures do not break the link.

## 11. Schema capability negotiation is mandatory

Immutable Play revisions can outlive app versions.

Every client advertises:

- supported schema versions;
- supported primitive capabilities;
- platform capability flags where relevant.

The server must not send a required primitive that the client cannot execute.

Rules:

- additive schema changes preferred;
- old compatibility fixtures stay in CI;
- primitive introduction includes fallback/eligibility behavior;
- removed primitives remain renderable for their supported retention window or are migrated to a new immutable revision;
- malformed or unsupported Plays never crash the feed.

## 12. Event delivery must tolerate offline, duplication, and clock skew

Client analytics are asynchronous.

Every durable event has:

- client event ID;
- actor/session IDs;
- client observed time;
- server receive time;
- schema version;
- retry count/transport metadata where useful.

Server ingestion deduplicates by event ID and never trusts client wall-clock time for ordering/security decisions.

Local spool is bounded by count/bytes/age and drops lowest-value telemetry before product-critical pending actions.

## 13. Cache and memory are budgets

A swipe feed can destroy low-end devices through prefetch alone.

Define separate budgets for:

- Play schemas;
- images;
- video buffers;
- audio buffers;
- custom-painted assets;
- local event spool;
- creator local files.

Respond to memory pressure by releasing prefetched/heavy resources first. Feed correctness must not depend on cache residency.

## 14. Accessibility is a renderer contract

Every primitive needs native and web semantics before launch eligibility.

Required checks include:

- TalkBack / VoiceOver;
- Flutter web semantics enabled and browser screen-reader smoke tests;
- 48×48 minimum interactive targets where applicable;
- large text/display scaling;
- high contrast;
- reduced motion;
- alternative path for drag/gesture-only tasks;
- no answer state conveyed only by color.

Custom canvas/CustomPainter interactions require explicit semantic nodes; visual rendering alone is not accessible.

## 15. Notifications are earned

Do not ask for notifications on first launch.

Good request moments include:

- user explicitly wants challenge responses;
- user follows a creator and requests updates;
- user enables a saved-interest alert.

Notification payloads must deep-link to a valid object and degrade safely if that object is removed.

## 16. Editorial tooling is required before 500–1,000 seed Plays

Do not manage seed content by editing JSON files manually.

Before large seeding, build an internal/editorial path for:

- create from approved templates;
- preview native/web behavior;
- source/provenance review;
- rights state;
- copy-budget validation;
- accessibility metadata;
- duplicate detection;
- publish/suspend;
- batch topic tagging/import where safe.

The seed corpus should exercise the same publication contract as community content.

## 17. Safe defaults when remote systems fail

- remote config unavailable → last-known-good, then compiled safe defaults;
- ranking unavailable → bounded curated fallback feed;
- analytics unavailable → interaction continues and spool is bounded;
- share attribution unavailable → canonical Play still opens;
- moderation signal unavailable → questionable new UGC does not gain broad distribution;
- media derivative unavailable → poster/retry/swipe, not frozen UI.

## 18. Release-device matrix

CI is necessary but insufficient for media/gesture/audio behavior.

Before controlled beta maintain a small physical-device matrix including:

- current iPhone;
- older supported iPhone;
- flagship Android;
- lower/mid-range Android;
- at least one 120 Hz device;
- Bluetooth audio route;
- Safari/Chrome mobile web.

Validate feed jank, memory growth, audio timing, video first frame, lifecycle suspend/resume, permission flows, and shared Play behavior.

## 19. Launch gate additions

Controlled beta additionally requires:

- strict Flutter CI green on committed lockfile;
- server/edge social metadata shell for shared Plays;
- web accessibility semantics enabled;
- process-death recovery for anonymous state and creator drafts;
- active-media ownership/lifecycle tests;
- browser/media compatibility matrix;
- compatible SDR video derivative from HEVC/HDR input;
- creator Terms acceptance + report + block;
- privacy manifest/Data Safety release checklist;
- bounded offline event spool;
- schema capability negotiation;
- physical-device smoke suite.
