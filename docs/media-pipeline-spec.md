# Mosaic — Media Pipeline Specification

## 1. Purpose

Creator supply fails if capturing, uploading, processing, or reusing media feels fragile.

Mosaic media must be fast to create, resilient on poor networks, safe to publish, and predictable for the Play runtime.

## 2. Creator acquisition sources

Supported acquisition paths should converge on one asset pipeline:

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

Recommended web tooling: Uppy + tus.

Native implementation may use tus directly or an equivalent resumable transport behind a shared upload contract.

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

## 6. Canonical derivatives

Runtime should consume a bounded media profile set rather than arbitrary creator files.

### Images

Generate:

- feed preview;
- standard display;
- high-density display where justified;
- thumbnail/social preview;
- dominant/placeholder metadata where useful.

### Video clips

Normalize to supported codecs/profiles and generate:

- low-startup mobile derivative;
- standard mobile derivative;
- optional higher-quality derivative;
- poster frame;
- duration/aspect metadata;
- captions/transcript artifact where speech is material.

### Audio

Generate:

- normalized playback derivative;
- waveform/analysis metadata only when the Play uses it;
- duration/sample metadata;
- transcript where speech conveys factual content.

Do not retain derivatives that serve no product use.

## 7. Media budgets

Creator UI enforces product-level limits before upload when possible.

Examples of configurable limits:

- clip duration by template;
- source upload maximum;
- image megapixels;
- audio duration;
- total assets per Play;
- aggregate prefetch budget.

Limits are server-configured and remotely adjustable.

## 8. Prefetch contract

Every asset exposes enough metadata for the feed/runtime to decide whether to prefetch.

Include:

- kind;
- byte size by derivative;
- duration/dimensions;
- priority hint;
- poster/placeholder;
- whether the Play can begin without the heavy asset.

The feed should prefetch a bounded next-window, not all upcoming video/audio.

## 9. Creator capture

Native capture should support the shortest useful loop:

- open camera/mic quickly;
- capture;
- trim where needed;
- retake;
- use immediately in Quick Create/Remix;
- background/resumable upload.

Do not ship a general-purpose video editor before templates demonstrate the need.

VisionCamera is the preferred candidate for advanced native camera capture when Expo camera primitives are insufficient.

## 10. Rights metadata

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

## 11. Remix behavior

When remixing:

- reusable structure may be copied without copying restricted media;
- non-reusable media becomes an empty required slot;
- reusable Mosaic media retains original attribution/rights lineage;
- a creator cannot change inherited rights declarations for an upstream asset.

## 12. Processing architecture

Media processing is asynchronous and idempotent.

Use explicit job states and deterministic derivative keys so retries do not create uncontrolled duplicates.

A processor should be replaceable; Play/runtime code depends only on managed asset records and delivery URLs.

FFmpeg-class processing may be used server-side for normalization/transcoding.

## 13. CDN and delivery

- assets are served through managed CDN URLs;
- publication does not expose raw object-store paths;
- cache keys are revision/derivative stable;
- revoked media must be removable quickly;
- signed URLs are used for private/draft assets;
- public published assets use safe immutable URLs where possible.

## 14. Poor-network behavior

Creator:

- resume interrupted upload;
- preserve local draft;
- show clear pending state;
- never discard a finished local capture because upload failed.

Consumer:

- prefer smaller derivative;
- poster/prompt can render before video;
- allow immediate swipe when media cannot load;
- retain already-fetched Plays for continued use.

## 15. Moderation hooks

Before an asset becomes recommendation-eligible:

- automated safety checks;
- adult/sexual-content rejection;
- malware/type validation;
- rights/provenance checks according to risk;
- human review path for flagged or high-impact content.

Mosaic never offers adult, erotic, or sexually explicit content.

## 16. Observability

Measure:

- capture → draft latency;
- upload start/failure/resume;
- bytes uploaded;
- processing latency;
- derivative failure;
- moderation latency;
- first-frame/startup latency by derivative/network;
- asset error rate in feed;
- abandoned creation attributable to media failure.

## 17. Success test

A creator on an unreliable mobile connection can capture a useful clip, build a Play around it, leave/reopen the app, resume upload, preview the final normalized asset, and publish without redoing work.
