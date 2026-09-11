# Android visual and interaction review

Device: Honor BVL-N49, 1280 × 2800, density 560. The display reported 120 Hz.
Flutter: pinned 3.44.7. Android application: `com.pullsar.mosaic_app`.

## Changes

- Give the dark Play its own material colors, text and icons independently of
  the surrounding app's light/dark preference. A regression reproduced 1.17:1
  scene-object contrast in light mode; foreground and accent now exceed 4.5:1.
- Coordinate warm paper, lavender ceramic, mineral green and orbital blue
  accents with the existing immutable presentation references.
- Keep phone utility controls below a centered, full-width stage. Previously,
  phones as narrow as 412 px could switch to a rail and shrink the content.
- Align scenes layered over a canvas through the existing `PlayCanvasStage`.
  The regression reproduced a 654 px scene over a 294 px canvas in a wide
  viewport. Pieces and targets now use the same bounds as the artwork.
- Retain light natural piano keys and dark accidental keys in either app mode.
  Correct the orb's light reflection and shaded side.
- Give Save/Share/More a quiet dark material surface; keep the existing touch
  targets and native activation behavior.
- Request light Android system-bar icons over the dark feed. The first phone
  screenshot exposed dark status-bar icons against the black background.

## Device evidence

The profile app installed and launched successfully. Manual ADB input exercised
forward/back feed swipes, an answer and its reveal, Save → Unsave, and opening
and dismissing More. UI Automator confirmed the resulting reveal, Unsave state,
and menu actions. No Dart exception appeared in the captured app log.

`apps/mosaic_app/tool/device_profile.dart` runs the normal app entrypoint. After
15 seconds of warm-up it records a 60-second window using the existing bounded
`PlayPerformanceProbe` (maximum 2,400 samples), then removes the callback.
The normal app entrypoint has no added profiling work.

| Measurement | Result |
| --- | ---: |
| Captured frames | 712 |
| Refresh rate | 120 Hz |
| Frame budget | 8.333 ms |
| p95 build | 0.745 ms |
| p95 raster | 2.426 ms |
| p95 total | 5.001 ms |
| Samples over total-time budget | 12 / 712 (1.69%) |

These figures describe one warm session containing swipes and answers. They do
not establish zero dropped frames or performance for every game, thermal state,
audio route, or device. The capture predates the system-bar and continuous-round
changes.

## Catalog boundary

The live API returned revision-2 starter artwork. The branch's integrity fixture
contains 59 Plays, including revision-4 scene-based matchsticks. The newer
catalog was reviewed in the release browser through temporary local fixture
routes and the same shared renderer. Production data and API CORS settings were
not changed. Installing an APK does not publish the newer immutable catalog.

## Verification

The full shared-renderer suite passes 260 tests and the full app suite passes
158 tests, including reviewed screenshot references at compact, large-text/RTL,
landscape, tablet and desktop sizes. The prior four screenshot mismatches are
resolved by the reviewed palette references in this pass.

Analysis and lockfile-enforced dependency resolution pass. All tracked and newly
added Dart files pass formatting; the root recursive formatter encounters a stale
deep Android build directory on Windows. The renderer suite used
`--no-track-widget-creation --concurrency=1` after the disk-full compiler stalls.
TypeScript checking passes. The broader API run records 219 passes, three unchanged
Linux-path expectation failures on Windows, and 20 database-dependent skips.
Those skips are not PostgreSQL acceptance evidence. Local Node is 22; CI requires
Node 24.

Physical audio latency, sustained thermal/battery behavior, VoiceOver/TalkBack,
iOS validation, and publishing the current catalog remain separate acceptance
work. The local Android SDK needed its pinned Gradle, NDK and API 37 packages;
its self-referencing `Sdk/Sdk` junction was removed without deleting SDK files.
