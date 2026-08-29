# Play performance profiling

This protocol is the acceptance gate for issue #3's remaining physical-device performance work. It measures the production renderer without adding always-on instrumentation to the consumer feed.

## Scope

Profile representative Plays on physical iOS and Android devices at their native refresh modes. Keep 60 Hz and 120 Hz results separate; a frame that is healthy at 60 Hz can miss the 8.33 ms 120 Hz budget.

Use Flutter profile mode for repeatable measurements. Release builds may be used for final spot checks, but debug-mode numbers are not acceptance evidence.

`PlayPerformanceProbe` is deliberately opt-in. Constructing it does not register a scheduler callback. Call `start()` only inside an explicit profiling harness immediately before presenting the Play, and always call `stop()` or `dispose()` at the end of the window.

## Required scenarios

Measure at least these paths on each target refresh class:

1. cold first presentation of a visual/canvas Play;
2. warm next-Play transition after the intended prefetch window is populated;
3. muted short-video presentation and first rendered video frame;
4. user-initiated audio from `Hear` through source/device readiness;
5. piano interaction;
6. drag/direct-manipulation interaction while feed paging is locked;
7. reveal/next-state transition;
8. background → foreground recovery for an eligible managed video.

Do not combine cold and warm media measurements into one aggregate.

## Fixed measurement window

For frame comparisons, capture a fixed interaction script and a bounded frame window. The default probe retains at most 600 frames, preventing an accidental long session from turning profiling into unbounded telemetry.

Record the actual device model, OS version, app commit SHA, Flutter version, refresh mode, scenario, and whether media was cold or warm. Keep the screen brightness and thermal state reasonably stable and avoid profiling while the device is thermally throttled.

## Metrics

For every frame window record:

- target refresh rate and derived frame budget;
- total frames;
- frames whose total span exceeds the target frame budget;
- over-budget ratio;
- p50 and p95 total frame span;
- p95 build duration;
- p95 raster duration;
- maximum total frame span;
- first-frame latency from probe start to first raster finish;
- user-audio readiness latency where applicable.

`markAudioReady()` must be called by the profiling harness only when the measured user-initiated audio path is actually ready. Do not use mount time or button-tap dispatch time as a substitute for readiness.

## Acceptance interpretation

The controlled-beta target remains a 60 fps minimum experience on representative devices. 120 Hz devices are measured separately rather than silently judged against a 60 Hz budget.

Treat a single long frame as diagnostic evidence, not an automatic product failure. Investigate persistent p95 or over-budget regressions, especially on swipe, direct manipulation, first frame, video start, and reveal transitions. Correlate build-heavy windows with widget work and raster-heavy windows with image decode, clipping, opacity, shader, or layer cost before changing the renderer.

Do not add decorative blur, clipping, opacity, or animation to a feed-critical path merely because a synthetic benchmark remains green.

## Result record

Use one row per device/scenario/refresh mode:

| Commit | Device | OS | Hz | Scenario | Cold/warm | Frames | Over budget | p50 total | p95 total | p95 build | p95 raster | Max | First frame | Audio ready |
| --- | --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `<sha>` | `<model>` | `<version>` | 60 | `<scenario>` | cold | 0 | 0% | — | — | — | — | — | — | — |

Physical measurements are manual acceptance evidence. CI validates the probe's budget/statistics behavior and renderer regressions, but CI does not satisfy the physical 60/120 Hz gate by itself.
