# Mosaic — Experience Design Specification

## 1. Design objective

Mosaic must feel as easy to enter and leave as a short-form feed while making the content itself more participatory.

The user should never feel trapped in a lesson, flow, or game they did not choose.

Primary interaction promise:

```text
Swipe if you don't want it.
Play if you do.
```

The Play itself is the interface. See [`visual-language-and-copy-spec.md`](visual-language-and-copy-spec.md) for the detailed brand, typography, copy, hierarchy, and attention rules.

## 2. Visual attention rule

Consumer Play surfaces target this attention budget:

- ~88% primary content/supporting visual context;
- ~9% controls/icons/motion/state feedback;
- ~3% visible text.

This is a hierarchy heuristic, not a literal pixel quota.

If the initial Play state looks like a card of text with media attached, redesign it.

## 3. Product surfaces

Launch navigation:

**Play · Saved · Create · Me**

### Play

Default landing surface. Full-screen feed.

### Saved

Lightweight collections.

### Create

Remix and Quick Create.

### Me

Preferences, muted topics/creators, creator identity, settings.

No dashboard is shown on app open.

## 4. Onboarding

Onboarding contains exactly two optional preference screens before feed entry.

### Screen 1

**What are you into?**

Use visual topic tiles/tag clusters with concise labels.

Required behavior:

- visual/icon/image support where useful;
- obvious selected state;
- search;
- no minimum selection;
- **Surprise me** escape.

### Screen 2

**Want to learn more about?**

Use the same visual system. Broad topics may expand into subtopics.

Rules:

- no third questionnaire;
- no prose explaining personalization;
- no proficiency test;
- no request for creator expertise;
- no progress theater;
- feed starts immediately after completion/skip.

## 5. Feed shell

One Play owns the viewport.

Persistent chrome is quiet and thumb-reachable.

Default persistent actions:

- Save;
- Share where appropriate;
- More.

Creator/topic attribution is secondary.

Do not build a TikTok-style tower of engagement metrics.

Progress exists only inside a multi-state Play and never implies a session obligation.

## 6. Swipe behavior

Vertical swipe dismisses the current Play and advances.

Rules:

- available from every Play state;
- never blocked by incorrect answers;
- never requires confirmation;
- direct manipulation does not accidentally trigger feed swipe;
- gesture arbitration is primitive-aware;
- current Play state may be preserved briefly for back navigation.

The gesture remains consistent even as Play content varies.

## 7. Engagement behavior

A Play communicates the action in one glance.

Preferred prompts:

- **Where is this?**
- **Which note?**
- **Pick one.**
- **Play it back.**
- **Find the route.**
- **What happens next?**
- **Look closer.**

No explanatory preamble.

## 8. Guess pattern

Structure:

1. media/context;
2. concise question;
3. 2–5 options or direct input;
4. immediate response;
5. short reveal;
6. optional deeper action.

Example:

*8-second coastal clip.*

**Where is this?**

Amalfi · Dubrovnik · Santorini · Valletta

Result:

**Dubrovnik**

`Medieval walls wrap the old city.`

No congratulation modal.

## 9. Choose pattern

Choose is preference under meaningful context, not trivia.

Weak:

> Lisbon or Marrakech?

Strong:

> **Four days. Cheap food. Warm nights.**
>
> Lisbon · Marrakech

A good Choose Play uses at least one meaningful constraint:

- budget;
- occasion;
- desire;
- role;
- trade-off;
- scenario.

After choice, the Play may show a concise comparison, ask one follow-up, record preference, or end.

Do not manufacture a correct answer.

## 10. Solve pattern

The challenge occupies most of the screen.

Rules:

- instruction fits in one glance;
- manipulation starts immediately;
- Reset only when useful;
- hint is optional;
- solution is concise;
- swipe remains available;
- score furniture appears only when score improves the game.

## 11. Play pattern

Play is direct interaction with media or objects.

Examples:

- piano keyboard;
- rhythm pad;
- map;
- drawing surface;
- ordering;
- drag/assembly.

Controls should resemble the thing being manipulated, not generic forms.

Piano example:

```text
Hear
 ↓
Play it back
 ↓
keyboard
 ↓
immediate visual/audio/haptic result
```

Use text only where the interaction would otherwise be ambiguous.

## 12. Discover pattern

Discover may be primarily experiential.

Examples:

- beautiful place;
- artwork;
- cultural scene;
- archival footage;
- prayer;
- unusual object;
- wildlife.

Natural actions can include:

- **Where is this?**
- **Hear**
- **Look closer**
- **What happened next?**
- **Pray**

Do not add an irrelevant quiz to force interactivity.

## 13. Short clips

Short clips are media, not a separate feed type.

Use for:

- travel/location guessing;
- cooking identification;
- cultural recognition;
- before/after prediction;
- musical identification;
- movement/sports analysis;
- historical/cultural scenes.

Rules:

- subject is visible immediately;
- prompt overlays only when needed;
- captions when speech matters;
- muted-first where appropriate;
- no passive long clip simply because video exists;
- primary action remains reachable without covering the subject.

## 14. Audio

Default:

**Hear**

Mosaic may remember sound preference after repeated behavior.

Rules:

- no surprising loud autoplay;
- replay is obvious;
- waveform only if functional;
- speech has transcript/captions;
- timing-sensitive Plays use measured latency/tolerance;
- accessible alternative where feasible.

## 15. Feedback

Feedback should be immediate and primarily sensory.

Prefer:

- state/color/shape change;
- object movement;
- subtle haptic;
- sound;
- concise reveal.

Avoid:

- `Great job!`;
- `Amazing!`;
- full-screen celebrations for trivial answers;
- shame/failure language;
- streak reinforcement.

The answer itself is usually the best feedback.

## 16. Save, Share, More like this

### Save

One tap. Saving does not imply homework.

### Share

Share the Play itself, not a marketing page.

### More like this

Explicit ranking signal distinct from Save.

Place it in a secondary action surface unless testing proves it deserves a persistent control.

## 17. Remix entry

Creation appears in context.

Eligible Plays expose:

**Remix**

or:

**Make yours**

Remix opens filled slots, never a blank Studio.

## 18. Quick Create

Create landing asks only:

**Make:**

Guess · Choose · Solve · Play · Discover

After selection, show the smallest valid field set.

Creator preview dominates the surface. Advanced settings remain hidden until requested.

## 19. Copy system

Consumer copy is sparse, literal, and functional.

Rules:

- prompt preferably 2–6 words;
- use verbs;
- no product jargon;
- no motivational filler;
- no AI self-reference;
- no fake urgency;
- no conversational padding;
- reveal is one short statement by default.

Prefer:

> **Play it back.**

Not:

> Try reproducing the sequence of notes you just heard.

Prefer:

> **£500. Four days. Pick one.**

Not:

> Imagine you are planning a four-day holiday with a limited discretionary budget.

## 20. Typography

Default cross-platform typeface: **Inter Variable** until brand testing justifies another choice.

Use a small hierarchy:

- prompt: Semibold;
- option/control: Medium;
- secondary/reveal detail: Regular;
- metadata: Regular/Medium at reduced emphasis.

Avoid Thin/Light functional text.

Do not mix display fonts in v1.

## 21. Visual direction

- edge-to-edge media;
- dominant subject/object;
- restrained material/glass only for floating controls;
- stable control positions;
- minimal permanent chrome;
- no card-within-card clutter;
- no decorative gradients/blur merely to look futuristic;
- content-specific color may dominate the viewport;
- visual hierarchy must survive small phones and large text settings.

The system should feel refined and quiet around playful content.

## 22. Motion

Motion communicates state, cause/effect, hierarchy, and feed movement.

Rules:

- no ambient bouncing CTA;
- no decorative continuous motion;
- animations remain interruptible;
- respect reduced motion;
- use the smallest motion that makes the interaction clearer.

## 23. Haptics

Use selectively for:

- answer lock;
- successful placement;
- rhythm/piano confirmation;
- invalid move where visual feedback is insufficient;
- meaningful completion.

Do not haptic every tap.

## 24. Accessibility

Visual-first never means inaccessible.

Required:

- generous touch targets;
- semantic labels for icon-only controls;
- no color-only result indication;
- captions/transcripts;
- reduced motion;
- adequate contrast;
- scalable text;
- alternate controls for drag/gesture-only interactions where needed;
- screen-reader ordering that follows the Play's logical action order.

Accessibility metadata is part of publication validation.

## 25. Loading behavior

A normal swipe should not land on an empty spinner.

Presentation order:

1. local shell/composition;
2. lightweight visual placeholder when needed;
3. primary media;
4. deferred secondary media.

If required media fails:

- retry safely;
- expose compact recovery when needed;
- keep swipe available.

## 26. Poor-network behavior

- bounded next-window prefetch;
- lower media derivative first when appropriate;
- no blind prefetch of all audio/video;
- preserve fetched Plays;
- upload analytics asynchronously;
- degrade decorative effects before degrading the core interaction.

## 27. Safety UX

More menu includes:

- Not interested;
- More like this;
- Mute topic;
- Mute creator;
- Report.

Mosaic never offers adult, erotic, or sexually explicit content and has no mature-content toggle.

## 28. Faith UX

Faith is an opt-in interest, not universal behavior.

Examples:

**Prayer for courage**  
**Pray**

or a sacred-art Discover Play.

Users who do not select or engage faith content should not receive it through normal wildcard exploration.

## 29. Notifications

Sparse and specific.

Good:

- **Sam challenged you.**
- **New piano Play from Ada.**

Bad:

- Your curiosity misses you.
- Don't lose your streak.
- You haven't played today.

## 30. Empty states

Use the object/action, not prose.

Saved:

> **Save anything worth keeping.**

Create:

> **Remix or make one.**

Avoid tutorials unless requested.

## 31. Performance acceptance

The interaction design is not accepted if visual effects cause obvious frame instability.

Target:

- 60 fps minimum experience goal;
- 120 Hz devices remain meaningfully smooth;
- no feed-critical intrinsic/layout excess;
- no expensive glass/blur merely for decoration;
- inactive audio/video/custom drawing resources are released quickly.

## 32. Success test

A first-time user should understand Mosaic by seeing and touching it, not by reading about it.

Within the opening feed they should encounter at least two visibly different interactions and infer:

> **This feed gives me things to do.**
