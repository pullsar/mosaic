# Mosaic — Media Pipeline Specification

## 1. Purpose

Creator supply fails if capturing, uploading, processing, or reusing media feels fragile.

Mosaic media must be fast to create, resilient on poor networks, safe to publish, and predictable for the Play runtime.

## 2. Creator acquisition sources

Supported acquisition paths converge on one asset pipeline:

- camera video;
- camera photo;
- microphone/audio recording;
- device library;
- file upload;
- existing Mosaic asset where reuse rights allow it;
- approved source import later;
- generated supporting media later under explicit provenance rules.

Creation should begin from the media when natural.

Example:

```text
RECORD 7s STREET CLIP
       ↓
USE IN MOSAIC
       ↓
SUGGEST: "Where is this?"
       ↓
ADD OPTIONS / SOURCE
       ↓
PREVIEW → PUBLISH
```

## 3. Asset lifecycle

```text
LOCAL
  ↓
UPLOADING
  ↓
RECEIVED
  ↓
VERIFYING
  ↓
PROCESSING
  ↓
MODERATING
  ↓
READY
  ↓
PUBLISHED USE
```

Terminal/error states:

- upload_failed;
- invalid_type;
- processing_failed;
- rights_blocked;
- moderation_blocked;
- deleted/tombstoned.

Play publication may only reference eligible `READY` assets.

## 4. Upload behavior

Uploads must be resumable for non-trivial media.

Requirements:

- client-generated upload intent;
- server-authorized destination;
- resumable/chunked transport;
- restart after application interruption where supported;
- progress state survives navigation;
- integrity verification after completion;
- retry without duplicate assets;
- user can continue editing metadata while upload runs.

Use a tus-class resumable protocol behind Mosaic's `UploadSession` contract. The specific Dart client remains replaceable and must be re-evaluated at implementation time for maintenance and platform coverage.

### Background behavior

Resumable does not mean guaranteed continuous background execution.

- creator draft/local asset is durable before upload begins;
- iOS/Android may suspend the app and pause transport;
- upload resumes after foreground/relaunch using the same upload session where valid;
- UI reports honest state such as `Uploading`, `Paused`, `Retry`;
- add native background transfer only after measured creator need and platform-safe implementation.

## 5. Source file handling

Never trust extension or client MIME alone.

Server verifies:

- actual media type;
- dimensions/duration;
- decodability;
- file size limits;
- malicious/polyglot payload risk;
- metadata policy.

Originals are quarantined from public delivery until verification completes.

Source media may include HEVC/H.265, HDR, variable frame rate, wide-gamut color, rotation metadata, unusual sample rates/channels, and very large dimensions. The pipeline must normalize rather than assume consumer compatibility.

## 6. Canonical derivatives

Runtime consumes a bounded media profile set rather than arbitrary creator files.

### Images

Generate:

- feed preview;
- standard display;
- high-density display where justified;
- thumbnail/social preview;
- dominant/placeholder metadata where useful.

### Video clips

Always generate a broadly compatible SDR launch derivative. Preferred baseline for launch is MP4/H.264 video with AAC audio, plus additional derivatives only when measured value justifies them.

Normalize/support:

- HEVC/H.265 source → compatible derivative;
- HDR/wide-gamut source → safe SDR fallback;
- variable frame rate;
- rotation/orientation metadata;
- silent video;
- poster frame;
- duration/aspect metadata;
- captions/transcript artifact where speech is material.

Do not make HEVC/HDR the only published derivative.

### Audio

Generate:

- normalized playback derivative;
- consistent sample/channel metadata;
- waveform/analysis metadata only when the Play uses it;
- duration/sample metadata;
- transcript where speech conveys factual content.

Do not retain derivatives that serve no product use.

## 7. Browser/device playback matrix

Media publication must be verified against a small compatibility matrix covering at minimum:

- Safari iOS;
- Chrome Android;
- Safari desktop;
- Chrome desktop;
- supported native iOS/Android players.

Rules:

- no Play depends on audible autoplay;
- muted autoplay is opportunistic, not required for correctness;
- `Hear`/tap-to-play is the reliable audio path;
- incompatible derivative falls back to another supported derivative or poster/retry state;
- media capability failure never freezes the feed.

## 8. Media budgets

Creator UI enforces product-level limits before upload where possible.

Configurable limits include:

- clip duration by template;
- source upload maximum;
- image megapixels;
- audio duration;
- total assets per Play;
- aggregate prefetch budget.

Limits are server-configured and remotely adjustable.

## 9. Prefetch contract

Every asset exposes enough metadata for the feed/runtime to decide whether to prefetch.

Include:

- kind;
- byte size by derivative;
- duration/dimensions;
- priority hint;
- poster/placeholder;
- whether the Play can begin without the heavy asset.

The feed prefetches a bounded next-window, not all upcoming video/audio.

Prefetch is constrained separately by memory class, connection quality, and media type. Correctness never depends on cache residency.

## 10. Flutter creator capture

Start with Flutter's first-party `camera` plugin and platform media pickers for normal capture/import.

Native creator capture should support the shortest useful loop:

- open camera/mic quickly;
- capture;
- trim where needed;
- retake;
- use immediately in Quick Create/Remix;
- resumable upload.

Permissions are contextual:

- use system photo/media pickers instead of broad storage access;
- request camera only when creator chooses capture;
- request microphone only when recording is requested;
- denial has a graceful import/skip path.

Do not ship a general-purpose video editor before templates prove the need.

A more specialized camera/native pipeline is introduced only when measured creator requirements exceed the first-party Flutter path.

## 11. Capture state

The local draft references a durable local asset record before upload starts.

At minimum persist:

- local asset ID;
- local URI/path handle as allowed by platform;
- media kind;
- capture/import time;
- upload session ID;
- upload state/progress;
- intended Play/draft reference;
- rights declaration state.

A completed local capture must never disappear merely because the network failed or the OS killed the process.

## 12. Rights metadata

Every creator-provided asset records:

- uploader;
- ownership/license declaration;
- source/reference if applicable;
- reusable-in-remix flag;
- attribution requirements;
- commercial-use eligibility if relevant;
- moderation state;
- takedown state.

Asset rights are separate from template/Play-structure remix rights.

## 13. Remix behavior

When remixing:

- reusable structure may be copied without copying restricted media;
- non-reusable media becomes an empty required slot;
- reusable Mosaic media retains original attribution/rights lineage;
- a creator cannot change inherited rights declarations for an upstream asset.

## 14. Processing architecture

Media processing is asynchronous and idempotent.

Use explicit job states and deterministic derivative keys so retries do not create uncontrolled duplicates.

A processor is replaceable; Play/runtime code depends only on managed asset records and delivery URLs.

FFmpeg-class processing may be used server-side for normalization/transcoding.

## 15. CDN and delivery

- assets are served through managed CDN URLs;
- publication does not expose raw object-store paths;
- cache keys are revision/derivative stable;
- revoked media must be removable quickly;
- signed URLs are used for private/draft assets;
- public published assets use safe immutable URLs where possible.

## 16. Poor-network behavior

Creator:

- resume interrupted upload;
- preserve local draft;
- show clear pending state;
- never discard a finished local capture because upload failed.

Consumer:

- prefer smaller compatible derivative;
- poster/prompt can render before video;
- allow immediate swipe when media cannot load;
- retain already-fetched Plays for continued use.

## 17. Flutter runtime lifecycle

Media adapters must release inactive resources aggressively.

Rules:

- one visible Play owns active media playback;
- only bounded nearby video/audio controllers stay warm;
- leaving viewport pauses/stops according to Play policy;
- background/inactive app lifecycle pauses non-background media;
- disposing a Play releases decoders, audio handles, timers, and custom painter/resources;
- app lifecycle interruptions preserve semantic Play state without assuming media controller continuity;
- resume recreates media controller state from Play state.

The feed must not accumulate native media resources as the user swipes.

## 18. Moderation hooks

Before an asset becomes recommendation-eligible:

- automated safety checks;
- adult/sexual-content rejection;
- malware/type validation;
- rights/provenance checks according to risk;
- human review path for flagged or high-impact content.

Mosaic never offers adult, erotic, or sexually explicit content.

## 19. Observability

Measure:

- capture → draft latency;
- upload start/failure/resume;
- bytes uploaded;
- processing latency;
- derivative failure by source codec/profile;
- moderation latency;
- first-frame/startup latency by derivative/network/browser;
- asset error rate in feed;
- active media controller/resource counts during long swipe sessions;
- abandoned creation attributable to media failure.

## 20. Success test

A creator on an unreliable mobile connection can capture a useful HEVC/HDR-capable-phone clip, build a Play around it, lose/reopen the app, resume upload, preview a normalized compatible derivative, and publish without redoing work; recipients can play the resulting media on supported native and mobile-web targets.
