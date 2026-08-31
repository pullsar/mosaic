# Magnetic Guest Play System

**Status:** Approved direction; implementation not started

**Date:** 2026-08-31

**Scope:** Guest Play feed composition, visual system, launch content, loading, conversion handoff, accessibility, and visual acceptance

**Supersedes:** The guest-home visual composition and conversion details in `2026-08-31-guest-first-home-design.md`. Its API, recovery, privacy, and bounded-supply decisions remain in force.

## Objective

Make the guest home page feel immediately alive, premium, and unmistakably Mixli: a first-time visitor lands directly in a Play, understands what to touch without explanation, gets an immediate response, and can browse enough value before Mixli asks for a relationship.

The experience should be psychologically magnetic through curiosity, agency, mastery, immediacy, variety, and trust. It must not depend on streaks, shame, fake urgency, autoplay audio, deceptive signup prompts, engagement metrics, or ambient visual stimulation.

## Audit evidence

The production surface is online and the guest feed returns six items, but the current composition is not visually shippable:

- the app header and Play prompt independently occupy the same top region, causing collisions;
- Play inputs and consumer utility controls independently occupy the same bottom region, causing overlap and intercepted taps;
- managed canvas coordinates expand against the entire viewport, so puzzles become sparse or distorted on desktop and landscape;
- dark-theme `primary` resolves to white, flattening authored canvas accents into monochrome;
- all six starter Plays use similar sparse managed-canvas artwork, so nominally different formats feel identical;
- the generic drag handle obscures the matchstick puzzle and does not resemble the manipulated object;
- reveal replaces the dominant object instead of preserving visual continuity;
- `Join Mixli` currently leads to an early-access placeholder rather than a real account path;
- Inter Variable is specified but not bundled or configured;
- overflow and reveal layers have insufficient surface separation;
- cold load can show a branded waiting state for several seconds instead of a reserved Play-shaped composition;
- current tests exercise isolated widgets but not the complete production guest composition.

These are ownership and content-system failures, not isolated spacing defects.

## Considered approaches

### Cosmetic patch

Move the current header and controls, add color, and retouch the six Plays. This would reduce visible collisions quickly but preserve competing layout owners and an unbounded canvas. The next prompt, input, or viewport variant would regress the composition.

### Unified composition system — selected

Give the app shell and Play renderer one shared viewport contract, then rebuild the flagship content against it. This fixes the structural causes while keeping one schema/engine/renderer path across guest, signed-in, preview, and sharing surfaces.

### Media-first replacement

Replace the starter catalog with strong photography and video first. This would improve first impression but would still collide with current chrome and would leave interactive canvas Plays unreliable across viewports.

## Experience contract

The Play remains the interface. The first meaningful frame is a Play-shaped surface, never a marketing page, topic picker, dashboard, or tutorial.

```text
┌─────────────────────────────────────┐
│              For You        Search  │
│                                     │
│  Concise prompt                     │
│                                     │
│        DOMINANT PLAY OBJECT          │
│      bounded canvas / full media     │
│                                     │
│       large contextual choices       │
│                               Save  │
│                               Share │
│                               More  │
│                                     │
│   Play      Saved     Create     Me │
└─────────────────────────────────────┘
```

This diagram expresses hierarchy, not fixed coordinates. On compact or landscape viewports, utilities may become a quiet horizontal dock when a rail would reduce the Play below its minimum usable stage. Utilities never carry public counts and never form an engagement tower.

### Composition ownership

Introduce one immutable composition environment shared by the app shell and `PlaySurface`. It defines:

- system-safe insets;
- quiet top chrome;
- prompt region;
- dominant content stage;
- contextual input region;
- utility region;
- persistent navigation region;
- keyboard and accessibility insets;
- viewport class and reduced-motion preference.

Children consume allocated regions; they do not independently hard-code top or bottom padding. The app must not create a second Play renderer. Guest, authenticated, preview, and shared views continue to compose the existing `play_schema → play_engine → play_flutter` path.

The production composition uses roughly 88% content, 9% controls and feedback, and 3% visible text as an attention heuristic. No element may overlap another element's hit target or semantic bounds.

### Header and navigation

The main Play has no persistent Mixli wordmark or logo watermark. Brand recognition comes from the composition, type, interaction, and content craft. The top chrome contains only the current feed label, `For You`, and Search. It recedes after interaction when doing so does not harm discoverability or accessibility.

Global navigation uses the established grammar `Play · Saved · Create · Me`. Guest taps on account-dependent destinations may open the conversion handoff, but the destinations remain stable so the product does not change shape after signup.

### Dominant content stage

- Photography and video may render edge-to-edge inside the content region with deliberate crop and safe focal positioning.
- Managed canvas renders in a bounded, aspect-aware stage rather than mapping normalized coordinates to the entire viewport.
- Each Play declares or derives an intended stage aspect family and safe focal region. The renderer letterboxes or crops according to that contract; it never stretches authored geometry.
- Compact landscape prioritizes the object and input side by side when vertical stacking would make either unusable.
- Desktop constrains the interactive stage to a deliberate editorial width instead of scattering elements across the browser.
- Unsupported or failed media preserves prompt, navigation, swipe, retry, and a curated fallback. A warm swipe never lands on a blank blocking spinner.

### Inputs and utilities

Each Play has one obvious contextual action. Choice targets are at least 48 logical pixels high and remain visually distinct from Save, Share, and More.

Save, Share, and More are quiet secondary utilities without counts. `More Like This` lives behind contextual disclosure or post-interaction feedback; it does not compete with the answer. Drag affordances resemble the manipulated object and provide a keyboard/screen-reader alternative. Inputs respond immediately before explanatory copy appears.

### Color and material

Content-specific color leads the viewport. System chrome remains disciplined and neutral.

Managed assets gain a versioned semantic palette contract, using roles such as background, foreground, accent, positive, negative, subdued, and surface rather than arbitrary widget-level hex values. Published legacy revisions retain a deterministic compatibility palette. New revisions are rejected when required contrast or role combinations are invalid.

Surfaces may use restrained elevation or translucency only where it clarifies hierarchy. Feed-critical paths avoid decorative gradients, blobs, heavy blur, stacked cards, glow, or shader effects. The aesthetic is puffy, posh, playful, and refined through proportion, material, spacing, and motion—not decoration.

### Typography

Bundle and configure Inter Variable through the existing app type system. Use Semibold for prompts, Medium for controls, and Regular for detail. Functional copy never uses Thin or Light. Text scales without clipping at 200%, and prompts remain literal, specific, and normally two to six words.

### Feedback, reveal, and motion

Interaction feedback is immediate and preserves the dominant object. A choice may lock, move, tint, annotate, or expose the answer in place; reveal must not replace the Play with an unrelated text page.

Motion is spring-like, interruptible, and causal. Typical micro-transitions complete in roughly 140–240 ms; feed swipes may continue according to the established gesture physics. Reduced-motion mode uses direct state changes or short fades. There is no confetti, permanent bounce, forced wait, blocking celebration, or surprise audio.

## Starter catalog

The launch surface cannot rely on six visually similar puzzle sketches.

### Content bar

The first production tranche contains 24–36 art-directed Plays. It is a quality floor for a compelling guest window, not a replacement for the product-spec beta target of 500–1,000 excellent Plays.

The first six impressions must include:

- at least three visibly different art directions or media treatments;
- at least two interaction types;
- no consecutive duplicate topic and no monotonous format run;
- a mixture of Guess, Choose, Solve, Play, and Discover semantics across the first twelve;
- complete attribution, rights/provenance, accessible labels, fallback assets, and media metadata.

All media is served through the established object-delivery path. Deployment rejects catalog entries whose primary visual, fallback, accessibility metadata, or rights metadata is incomplete.

### Flagship-six rewrite

The existing concepts may remain, but they must be re-authored as distinct premium pieces:

1. **Move one match.** Warm tactile match materials, object-shaped drag feedback, and an in-place equation reveal.
2. **Which city is this?** Strong location photography with restrained answer chips and a concise fact reveal.
3. **What comes next?** Rhythmic material tiles with motion that explains the pattern.
4. **Which path stays in orbit?** Deep-indigo orbital illustration with clearly labeled paths and preserved trajectory feedback.
5. **Pick the better recharge.** Editorial color fields and honest preference semantics; no manufactured correct answer.
6. **Complete the sequence.** Typographic number tiles with clear hierarchy and in-place solution annotation.

These examples establish range; they do not authorize a parallel bespoke renderer. They must be expressible through the shared schema and renderer or drive a deliberate, reusable schema extension.

## Loading and recovery

The app reserves the final composition immediately so late data cannot shift chrome or inputs.

- first nonblank Play-shaped shell target: no later than 100 ms after Flutter's first frame;
- cached/local playable target: 500 ms on supported warm starts;
- network first-Play target: p75 at or below 2.5 s on the defined target mobile profile;
- a branded waiting message may appear only inside the reserved content stage and must not block navigation, retry, or swipe to locally available supply;
- ranking or transport failure falls back to safe curated supply before showing an empty state;
- loading, retry, and stale async completion may not replace the current Play after a rapid swipe.

Instrument time to first Play-shaped frame, time to first playable interaction, media-ready time, fallback rate, and retry recovery. Performance targets are release gates only after the target device and network profiles are recorded with the measurements.

## Conversion handoff

Mixli demonstrates value before asking a guest to sign up.

The conversion prompt becomes eligible after either:

- five distinct Play views plus at least one meaningful interaction; or
- eight distinct Play views without an interaction.

It never interrupts a drag, answer animation, media control, or reveal. Dismissal resumes the feed in place and applies a session cooldown. A second prompt requires materially more browsing and must not appear repeatedly during the same short session.

`Join Mixli` is reserved for a working managed-authentication path. Until that security-sensitive identity tranche exists, the truthful label is `Get early access`, and the destination must describe exactly what submitting interest does. A placeholder must never impersonate account creation. Anonymous actor proof and account identity remain separate security concepts.

## Accessibility contract

- Screen-reader order is prompt, dominant object, contextual input, utilities, then global navigation.
- All icon-only controls have accessible names; visual order and focus order agree.
- Feedback is never color-only, and media meaning has captions or transcripts.
- Touch targets are at least 48 logical pixels for primary interaction and at least 44 for secondary controls.
- Keyboard and switch users can operate choices, navigation, menus, and every drag alternative.
- The composition remains usable at 200% text scale, in RTL, with high contrast, and with reduced motion.
- Focus, menu, and bottom-sheet transitions return to a logical origin without trapping navigation.

## Performance and reliability contract

- Protect 60 fps on supported baseline devices and preserve meaningful smoothness on 120 Hz devices.
- Keep feed-critical layers, clipping, blur, shaders, and repaint boundaries measured and bounded.
- Decode media near its rendered dimensions and bound the warm window, memory cache, concurrent requests, and retries.
- Render local composition first, primary media second, and deferred assets last.
- Preload only the bounded next window; release inactive video, audio, and custom drawing resources quickly.
- Fence asynchronous callbacks by Play identity and revision so stale work cannot mutate the current viewport.
- Never autoplay unexpected audio, including after lifecycle resume.

## Testing and visual acceptance

Implementation follows test-driven development and runs executable gates on the deployment/CI server, not the developer PC.

### Composition harness

Add a production-composition harness containing the real guest shell, `PlaySurface`, contextual input, consumer utility controls, navigation, prompt/reveal states, and conversion sheet. Isolated component goldens remain useful but are not sufficient.

The harness covers at least:

- 320 × 640 compact phone;
- 390 × 844 reference phone;
- 844 × 390 compact landscape;
- 768 × 1024 tablet;
- 1024 × 768 compact desktop;
- 1440 × 900 desktop;
- text scales 1.0, 1.6, and 2.0;
- LTR and RTL;
- reduced motion;
- keyboard focus and semantics;
- initial, selected, incorrect, correct, reveal, loading, media-failure, overflow-menu, and conversion states.

Geometry assertions fail when semantic or hit-test bounds overlap reserved regions. Every flagship Play receives reference screenshots at phone, landscape, and desktop sizes. Test fonts must render real glyphs so goldens cannot pass as blocks or placeholders.

### Server and live acceptance

The exact workflow commands owning each changed path run at the deployed commit on the server. Release acceptance also includes:

- web release build and real Chrome checks;
- live navigation through Cloudflare from cold and warm sessions;
- successful guest API and media delivery with curated fallback exercised;
- interaction through the first conversion eligibility point and dismissal;
- keyboard, large-text, and screen-reader smoke checks;
- physical-device frame profiling for the explicit 60/120 Hz acceptance criteria.

## Rollout sequence

1. **Composition foundation:** shared regions, bounded canvas, typography, utility/input arbitration, and production goldens.
2. **Flagship rewrite:** re-author the first six and validate palette, feedback, reveal, loading, and responsive behavior.
3. **Catalog expansion:** ship 24–36 art-directed Plays with complete media and metadata through the established delivery path.
4. **Truthful conversion:** ship `Get early access` until real managed authentication is ready; then enable `Join Mixli` through its separately reviewed identity tranche.
5. **Canary and verification:** deploy, run live browser acceptance, inspect performance/error telemetry, and expand traffic only when the release gates hold.

Each phase is independently reversible at the catalog or deployment level. Legacy published revisions continue rendering through the compatibility palette and existing capability negotiation.

## Acceptance criteria

The guest Play system is ready when all of the following are true:

- no production-composition golden or geometry assertion contains header/prompt, input/utility, menu/reveal, or navigation overlap;
- all reference viewports preserve one dominant object and an obvious primary action;
- managed canvas geometry stays proportionate across phone, landscape, tablet, and desktop;
- the first six impressions meet the stated variety contract and contain no missing primary/fallback visual;
- correct, incorrect, preference, reveal, loading, and failure states preserve navigation and the current Play context;
- the conversion prompt appears only at an eligible safe moment, dismissal returns in place, and its wording matches the real destination;
- Inter Variable, accessible names, focus order, non-color feedback, drag alternatives, 200% text, RTL, and reduced-motion behavior pass the owning tests and manual checks;
- server-side workflow gates, release builds, live Cloudflare browser checks, and measured performance targets pass at the exact deployed commit;
- a first-time user can know what to do by seeing and touching the surface without reading an explanation.

## Out of scope

- replacing the recommendation architecture;
- building a second renderer or arbitrary mini-website runtime;
- public engagement counts, comments, streaks, or notification pressure;
- decorative visual effects without a measured interaction purpose;
- collapsing anonymous proof-of-possession into account identity;
- claiming the 24–36 Play launch tranche satisfies the 500–1,000 Play beta supply target.
