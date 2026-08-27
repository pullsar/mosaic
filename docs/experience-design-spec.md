# Mosaic — Experience Design Specification

## 1. Design objective

Mosaic must feel as easy to enter and leave as a short-form feed while making the content itself more participatory.

The user should never feel trapped in a lesson, flow, or game they did not choose.

Primary interaction promise:

```text
Swipe if you don't want it.
Play if you do.
```

## 2. Product surfaces

Launch navigation:

**Play · Saved · Create · Me**

### Play

Default landing surface. Full-screen feed.

### Saved

Lightweight collections of items the user wants to revisit.

### Create

Remix and Quick Create entry.

### Me

Preferences, muted topics/creators, creator identity, basic settings.

No dashboard is shown on app open.

## 3. Onboarding

Onboarding contains exactly two optional preference screens before feed entry.

### Screen 1

**What are you into?**

UI:

- visual tag cloud;
- clear selected state;
- search;
- no minimum selection;
- **Surprise me** escape.

Purpose: seed entertainment/interest affinity.

### Screen 2

**What do you want to learn more about?**

UI:

- same visual language;
- broad topics can expand into subtopics;
- no minimum selection;
- Skip.

Purpose: seed learning intent separately.

### Rules

- no third questionnaire;
- no proficiency quiz during onboarding;
- no request for creator expertise during onboarding;
- feed begins immediately after completion/skip.

## 4. Feed shell

One Play owns the viewport.

Persistent controls must be minimal and thumb-reachable.

Required affordances:

- Save;
- More;
- creator/topic attribution where useful;
- progress only inside multi-state Plays, never as a session obligation.

The content and interaction surface take visual priority over navigation chrome.

## 5. Swipe behavior

Vertical swipe dismisses the current Play and advances.

Rules:

- available from every Play state;
- never blocked by incorrect answers;
- never requires confirmation;
- direct manipulation should not accidentally trigger feed swipe;
- gesture arbitration must be primitive-aware;
- current Play state may be preserved briefly for back navigation.

## 6. Engagement behavior

A Play should communicate what to do in one glance.

Preferred interaction copy:

- **Where is this?**
- **Which sounds warmer?**
- **Pick one.**
- **Play it back.**
- **Find the route.**
- **What happens next?**
- **Look closer.**

Avoid explanatory preambles.

## 7. Guess pattern

Structure:

1. media/context;
2. one short question;
3. 2–5 options or direct input;
4. immediate response;
5. concise reveal;
6. optional next action.

Example:

*8-second coastal clip.*

**Where is this?**

Amalfi · Dubrovnik · Santorini · Valletta

Result:

**Dubrovnik, Croatia**

One useful fact.

No modal congratulation screen.

## 8. Choose pattern

Choose is not trivia.

It should expose preference under a meaningful scenario.

Weak:

> Lisbon or Marrakech?

Strong:

> **Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking.**
>
> Lisbon · Marrakech

A good Choose Play has at least one of:

- budget;
- occasion;
- desire;
- constraint;
- role;
- trade-off;
- scenario.

After choice, the Play may:

- show a concise comparison;
- ask one follow-up;
- personalize a recommendation signal;
- end immediately.

Do not pretend preference has a correct answer.

## 9. Solve pattern

The challenge itself should occupy most of the screen.

Rules:

- instructions visible without scrolling;
- manipulation starts immediately;
- Reset appears only when useful;
- hint is optional;
- solution/reveal is concise;
- swipe remains available.

Avoid score furniture unless score adds to the game.

## 10. Play pattern

Play is direct interaction with media or objects.

Examples:

- piano keyboard;
- rhythm pad;
- map;
- drawing surface;
- ordering;
- drag/assembly.

Controls should resemble the thing being manipulated, not generic form widgets.

Example piano flow:

1. **Hear it**;
2. sound plays;
3. **Play it back**;
4. keyboard appears;
5. immediate response;
6. replay or swipe.

## 11. Discover pattern

Discover is allowed to be mostly experiential.

Examples:

- beautiful place;
- artwork;
- cultural scene;
- archival footage;
- prayer;
- unusual object;
- wildlife.

Interaction is added only when natural.

Good:

- **Where is this?**
- **Hear it**
- **Look closer**
- **What happened next?**
- **Pray**

Bad:

Adding an irrelevant quiz to every image to satisfy an “interactive” metric.

## 12. Short clips

Short clips are media, not a separate feed type.

Recommended use:

- travel/location guessing;
- cooking identification;
- cultural recognition;
- before/after prediction;
- musical identification;
- movement/sports analysis;
- historical/cultural scene.

Rules:

- hook/action visible immediately;
- clips remain short enough to start quickly;
- captions when speech matters;
- muted-first where appropriate;
- no long passive clip simply because video is available.

## 13. Audio

Default behavior:

**Tap to hear**

Mosaic may remember a user's sound preference after repeated behavior.

Rules:

- never surprise with loud playback;
- replay must be obvious;
- waveform is optional, not decorative requirement;
- speech requires captions/transcript;
- audio games need accessible alternatives where feasible.

## 14. Feedback

Feedback should be immediate and proportional.

Correct:

- small visual state change;
- subtle haptic;
- answer reveal.

Incorrect:

- show difference/answer;
- allow another attempt where the format benefits;
- no punitive copy.

Avoid:

- full-screen celebrations after trivial actions;
- shame/failure language;
- manipulative streak reinforcement.

## 15. Save

Save must be one tap.

Automatic collection suggestions may be inferred from topic:

- Travel;
- Restaurants;
- Music;
- Art;
- Things to try.

User can rename/create collections.

Saved items are not shown as incomplete work.

## 16. Remix entry

Creation should appear contextually.

Eligible Plays expose **Remix** in the More/action surface and optionally after completion.

Example:

**Make one like this**

Remix opens directly into filled slots; never into an empty Studio.

## 17. Quick Create

Create landing screen:

**What are you making?**

- Guess
- Choose
- Solve
- Play
- Discover

After selection, show the smallest valid field set.

Do not expose advanced layout controls until creator asks for Studio.

## 18. Copy system

Copy is functional and concise.

### Rules

- hook in one glance;
- verbs over explanations;
- avoid product jargon in consumer UI;
- do not call items “learning objects” or “microlearning”;
- no motivational filler;
- no guilt copy;
- no fake urgency.

Prefer:

> **Play it back.**

Not:

> Try reproducing the sequence of notes you just heard.

Prefer:

> **£500. Four days. Pick one.**

Not:

> Imagine you are planning a four-day holiday with a limited discretionary budget.

## 19. Visual direction

- edge-to-edge media;
- high visual contrast;
- restrained glass surfaces for floating controls;
- strong typography hierarchy;
- content-specific color can dominate the viewport;
- controls remain visually stable across Plays;
- minimal permanent chrome;
- no card-within-card visual clutter.

The system should feel refined and calm even when the content is playful.

## 20. Motion

Motion communicates:

- state transition;
- correct/incorrect resolution;
- drag/drop consequence;
- feed movement;
- hierarchy.

Motion should not become constant ambient stimulation.

Respect reduced-motion settings.

## 21. Haptics

Use selectively:

- answer lock;
- successful placement;
- rhythm/piano confirmation;
- invalid move;
- completion where meaningful.

Do not haptic every tap.

## 22. Accessibility

Required:

- large touch targets;
- semantic labels;
- keyboard/switch alternatives where applicable;
- no color-only result indication;
- captions/transcripts;
- reduced motion;
- adequate contrast;
- alternative to drag where practical;
- scalable text without destroying interaction layout.

Accessibility requirements are part of Play publication validation.

## 23. Loading behavior

A swipe must never land on an empty spinner if avoidable.

Order of presentation:

1. local/feed shell;
2. prompt/placeholder derived from Play metadata;
3. primary media;
4. secondary/deferred media.

If required media fails:

- retry silently where safe;
- show compact recovery action;
- allow immediate swipe.

## 24. Poor network behavior

- prefetch bounded next-window;
- prefer lower media derivative first;
- never download all upcoming video/audio;
- degrade animations before interaction;
- preserve already-fetched Plays for continued use;
- send analytics asynchronously.

## 25. Safety UX

More menu contains:

- Not interested;
- Mute topic;
- Mute creator;
- Report.

Mosaic never offers adult, erotic, or sexually explicit content, and there is no mature-content preference toggle.

## 26. Faith UX

Faith is an ordinary opt-in interest, not a universal system behavior.

Examples:

**A short prayer for courage**  
**Pray**

or:

Sacred-art Discover Play.

Users who do not select or engage with faith content should not receive it through normal ranking exploration.

## 27. Notifications

Launch notifications should be sparse and specific.

Good:

- **Sam challenged you to this.**
- **A new piano Play from a creator you saved.**

Bad:

- Your curiosity misses you.
- Don't lose your streak.
- You haven't played today.

## 28. Empty states

Saved empty state:

> **Save anything worth coming back to.**

Create empty state:

> **Remix a Play or make one.**

Avoid tutorials unless user asks.

## 29. Success test

A first-time user should understand Mosaic by using it, not by reading about it.

Within the opening feed, they should experience at least two visibly different interaction types and understand the product promise:

> **This feed gives me things to do, not just things to watch.**
