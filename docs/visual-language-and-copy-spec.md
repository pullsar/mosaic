# Mixli — Visual Language & Copy Specification

## 1. Purpose

Mixli succeeds only if the Play itself feels more immediate than the interface around it.

The product should be understood primarily through media, direct manipulation, motion, spatial composition, and familiar controls. Text exists to orient, disambiguate, label, or reveal—not to explain the product at length.

Core rule:

> **The Play is the interface.**

## 2. Attention budget

Use this as a design budget, not a literal pixel-count requirement:

- **~88% primary content + supporting visual context**
- **~9% controls, icons, motion, and state feedback**
- **~3% visible text**

The ratio describes intended visual attention. A screen may depart from it for accessibility, legal, creator, or complex interaction needs, but consumer Play surfaces should visibly feel content-dominant.

### Practical consequence

A Play viewport should usually contain:

- one dominant visual/audio/interactive object;
- one concise prompt when needed;
- only the controls required to act or leave;
- no paragraph explaining what the user is seeing.

## 3. Psychology model

### 3.1 Agency before guidance

People must be free to swipe, answer, replay, inspect, or leave without completing a prescribed flow.

Do not:

- lock the feed behind completion;
- force tutorials before use;
- block dismissal after an incorrect answer;
- auto-advance through explanatory screens the user did not request.

### 3.2 Recognition over recall

Use familiar gestures, recognizable controls, direct previews, imagery, sound, and visible choices instead of asking people to remember rules.

The interaction grammar must stay stable even while content varies.

### 3.3 One dominant question per viewport

A Play should create one clear cognitive target:

- Where is this?
- Which sounds better?
- Play it back.
- Pick one.
- Find the route.

Do not combine multiple instructions, metadata panels, creator promotion, and educational explanation on the same initial state.

### 3.4 Progressive disclosure

Show detail only after interest is demonstrated.

Initial state:

```text
VISUAL / SOUND / OBJECT
+ concise action
```

After engagement:

```text
REVEAL
+ optional deeper context
```

Sources, creator detail, explanations, and secondary actions live one interaction deeper unless essential to the Play.

### 3.5 Feedback should be faster than explanation

Prefer:

- object movement;
- highlight;
- subtle haptic;
- sound;
- reveal animation;

before explanatory text.

The user should feel the result before reading about it.

### 3.6 Visual continuity lowers interaction cost

Keep stable:

- feed swipe direction;
- save/share/more placement;
- answer-state behavior;
- back behavior;
- audio replay affordance;
- creator attribution position.

Novelty belongs in the Play content, not in relearning the app.

### 3.7 Remove extraneous processing

Every word, ornament, icon, animation, badge, and sound competes for attention.

A decorative element must justify itself by improving one of:

- comprehension;
- hierarchy;
- interaction confidence;
- feedback;
- emotional quality of the content.

Otherwise remove it.

## 4. Consumer surface hierarchy

Priority order:

1. **Play content/object**
2. **Required action**
3. **Immediate result/feedback**
4. **Exit/save/share controls**
5. **Attribution/secondary context**

Never reverse this hierarchy by making navigation, captions, badges, or creator identity visually louder than the Play.

## 5. Copy budget

### Initial Play prompt

Preferred: **2–6 words**  
Soft maximum: **10 words**  
Hard maximum: **14 words**, except scenario-based Choose Plays.

Examples:

- **Where is this?**
- **Which note?**
- **Play it back.**
- **Pick one.**
- **What happens next?**

### Situated choice

Use one compact scenario line followed by the options.

Preferred pattern:

> **Four days. Cheap food. Warm nights.**
>
> Lisbon · Marrakech

Longer context is allowed only when the constraint materially changes the decision.

### Reveal

Preferred: one short statement.

Example:

> **Dubrovnik, Croatia**
>
> Medieval walls wrap the old city.

Do not append a mini article. Deeper context is optional.

### Buttons

Prefer one- or two-word verbs:

- Hear
- Replay
- Save
- Share
- Remix
- Reveal
- Try again
- More like this

Avoid:

- Continue your journey
- Learn more now
- Start exploring
- Unlock insights

## 6. Voice

Mixli should sound:

- intelligent;
- direct;
- curious;
- calm;
- specific;
- human.

It should not sound:

- corporate;
- motivational;
- teacherly;
- synthetic;
- overly cheerful;
- self-congratulatory.

### Avoid AI-slop patterns

Do not use filler such as:

- Let's dive in
- Ready to explore?
- Unlock
- Embark on
- Journey
- Curated just for you
- Powered by AI
- Discover the magic of
- Great job!
- Amazing!
- Your curiosity awaits
- Here's something fascinating

unless a specific context makes the wording genuinely necessary.

### Feedback

Prefer the information itself.

Weak:

> Great job! You got it right! Dubrovnik is the correct answer.

Strong:

> **Dubrovnik.**

Weak:

> Oops! That's not quite right. Give it another try!

Strong:

> **Not this one.**
>
> Try again

Often even that text is unnecessary if visual feedback is obvious.

## 7. Typography

### Typeface

Use **Inter Variable** as the default cross-platform product typeface unless later brand work proves a materially better option.

Reasons:

- neutral enough to let content lead;
- broad weights;
- highly legible at small sizes;
- open and portable across Flutter targets.

Do not introduce a display font in v1 merely to appear branded.

### Weight

Default to:

- Regular for secondary text;
- Medium for controls;
- Semibold for prompts/reveals.

Avoid Thin/Light weights for functional text.

### Roles

Use a small role system rather than many arbitrary sizes:

- `playPrompt`
- `choiceLabel`
- `revealTitle`
- `revealDetail`
- `controlLabel`
- `metadata`

The hierarchy should rely on placement, weight, scale, and contrast—not decorative type treatments.

## 8. Branding

Mixli's brand should be expressed through:

- quality of content selection;
- fluid transitions;
- tactile feedback;
- disciplined composition;
- elegant media treatment;
- restrained material/glass surfaces;
- consistent interaction grammar.

The logo and chrome should not compete with the feed.

### Brand presence

On the main Play surface:

- no persistent wordmark;
- no large branded header;
- no decorative slogan;
- no logo watermark over creator media.

Brand becomes evident through craft and consistency.

## 9. Material and chrome

Use translucent/glass-like surfaces only for transient controls or navigation floating above content.

Rules:

- content layer remains visually clean;
- glass is not a decorative content background;
- avoid stacked translucent cards;
- avoid blur if it harms frame time or legibility;
- use blur/material sparingly on low-end devices.

## 10. Icons

Use familiar icons when recognition is high:

- save;
- share;
- more;
- replay;
- mute/unmute;
- close/back.

Do not invent a custom pictogram when a standard symbol is clearer.

Every icon still requires an accessibility label.

A visible text label is added only when the icon's meaning is ambiguous or critical.

## 11. Motion

Motion must communicate:

- feed movement;
- state transition;
- cause/effect;
- answer resolution;
- successful placement;
- hierarchy.

Motion must not become ambient stimulation.

### Rules

- no permanent bouncing CTA;
- no confetti for trivial answers;
- no animated badge clutter;
- respect reduced-motion settings;
- animations must remain interruptible by swipe/back.

## 12. Feed chrome

Default persistent controls should be no more than the minimum set required for the current surface.

Prefer icon-first controls for:

- Save
- Share
- More

Creator/topic attribution should be quiet and positioned outside the primary focal area.

Avoid a right-side tower of engagement metrics.

## 13. Onboarding

Onboarding should feel like selecting visuals, not filling a form.

### Interest selection

Prefer:

- image/icon-backed topic tiles;
- short labels;
- responsive tag clusters;
- immediate selection feedback.

Avoid:

- explanatory cards;
- paragraphs about personalization;
- proficiency questions;
- progress theater.

Copy:

> **What are you into?**

Then:

> **Want to learn more about?**

Use shorter phrasing in-product if testing shows it is clearer.

## 14. Creator UI

Creator surfaces may contain more text because they support precision, but the same principles apply:

- preview dominates;
- fields are contextual;
- only required controls are shown;
- advanced settings are progressively disclosed;
- template structure is visual where possible;
- field labels are literal, not conversational.

Good:

- Prompt
- Correct answer
- Reveal
- Source

Bad:

- Tell us the exciting question you'd like your audience to engage with

## 15. Accessibility exception

The visual-first rule must never remove information needed for accessibility.

Requirements include:

- semantic labels;
- captions/transcripts;
- scalable text;
- adequate contrast;
- non-color-only state feedback;
- alternatives to gesture-only controls where required.

Accessibility text may exist semantically without being visually prominent.

## 16. Performance psychology

Perceived quality depends on immediate response.

A beautiful interface that hesitates feels worse than a simpler interface that reacts instantly.

Design therefore assumes:

- 60 fps as minimum target;
- 120 Hz devices should remain meaningfully smooth;
- no spinner after a normal swipe;
- placeholder/media transitions preserve composition;
- haptic/audio feedback is synchronized tightly with interaction;
- expensive blur, clipping, shader, and layered effects are performance-budgeted.

## 17. Review checklist

Before approving a consumer screen, ask:

1. What is the first thing the eye sees?
2. Is it the Play itself?
3. Can the user understand the action without explanation?
4. Can any visible sentence be shortened or removed?
5. Can any label become a familiar icon?
6. Does every animation communicate state?
7. Can the user leave immediately?
8. Does the screen still work with large text/reduced motion?
9. Does the content remain dominant on a small phone?
10. Would this screen still make sense with all marketing language deleted?

If the answer to 2, 3, 7, or 10 is no, redesign it.

## 18. Success test

A first-time user should understand Mixli by seeing and touching it.

The desired reaction is not:

> I understand the explanation.

It is:

> I know what to do.
