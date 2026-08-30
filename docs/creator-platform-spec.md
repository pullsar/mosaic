# Mixli — Creator Platform Specification

## 1. Purpose

The creator system is the primary supply-side moat.

Mixli should make interactive micro-content as easy to create and reuse as short-form video templates are today, without giving creators arbitrary application code.

The creator loop is:

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

## 2. Creator product goals

- A normal user can remix a good Play without reading documentation.
- A knowledgeable user can turn one useful idea into a playable experience quickly.
- Skilled creators can invent reusable interaction formats.
- Successful formats can spread independently of the original topic.
- Creator reputation reflects usefulness and reuse, not only follower count.
- Consumer demand feeds directly back into creator opportunity.

## 3. Non-goals

The creator platform is not:

- a generic video editor;
- a website builder;
- a code sandbox;
- a long-form publishing CMS;
- an AI content firehose;
- an adult-content creator platform.

## 4. Creation levels

### Level 1 — Remix

Default creation path.

Flow:

1. User plays an eligible Play.
2. Taps **Remix**.
3. Existing template opens with editable slots.
4. Creator replaces content.
5. Production runtime renders live preview.
6. Validation runs.
7. Publish.

The creator never sees irrelevant configuration.

Example remix slots for **Where is this?**:

- clip/image;
- prompt;
- answer options;
- correct option;
- reveal;
- source;
- topics.

Target: a straightforward remix should be publishable in under one minute by an experienced user.

## 5. Level 2 — Quick Create

Creator taps **Create** and chooses:

**Guess · Choose · Solve · Play · Discover**

Each path asks only for fields required by that format/template family.

### Example — Choose

**Situation**  
`Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking.`

**Option A**  
Lisbon + media

**Option B**  
Marrakech + media

**After choice**  
Optional follow-up/reveal.

**Publish**

No canvas or timeline appears unless the creator explicitly enters Studio.

## 6. Level 3 — Studio

Studio is for power creators building reusable structures.

It exposes constrained blocks:

### Media

- image;
- clip;
- audio;
- text;
- map;
- animation;
- simple 3D.

### Input

- tap;
- choose;
- type;
- drag;
- draw;
- play note;
- tap rhythm;
- locate on map;
- record sound.

### Logic

- correct;
- compare;
- branch;
- score;
- sequence;
- attempt count;
- timer.

### Response

- reveal;
- animate;
- sound;
- haptic;
- explanation;
- source.

### Flow

- next state;
- branch;
- end;
- another Play.

Studio still produces declarative Play/template data interpreted by the production runtime.

## 7. Templates as first-class assets

A template includes:

- runtime graph;
- layout constraints;
- editable slot definitions;
- default transitions;
- response behavior;
- animation/haptic choices;
- validation rules;
- preview fixture;
- schema version;
- creator attribution.

A template should be topic-independent when possible.

Example:

**Which sounds better?** can support instruments, cars, birds, singers, languages, speakers, or engines.

## 8. Typed slots

Each template exposes only declared slots.

Example:

```json
{
  "name": "answerOptions",
  "type": "choice_list",
  "min": 2,
  "max": 5,
  "required": true
}
```

Other slot types:

- short text;
- rich text with strict length cap;
- image;
- clip;
- audio;
- option list;
- fact/source;
- map place;
- numeric range;
- color/theme token;
- reveal copy.

Slot constraints are validation, not suggestions.

## 9. Creator preview

Preview must run the exact production runtime and schema version.

No duplicated “preview renderer.”

Preview supports:

- phone viewport;
- sound on/off;
- reduced motion;
- accessibility labels;
- slow-network simulation;
- restart;
- inspect state transition.

## 10. Publication model

States:

```text
DRAFT → VALIDATING → REVIEW/READY → PUBLISHED → ARCHIVED
```

A published revision is immutable.

Editing a published Play creates a new revision.

Distribution can be suspended independently of archival state for moderation reasons.

## 11. Remix lineage

Every derivative records lineage:

```text
Template Revision
       ↓
Play Revision
       ↓
Remix Revision
       ↓
Further Remix
```

Store:

- immediate parent;
- root template;
- original creator;
- template creator;
- derivative creator;
- revision IDs;
- publication timestamps.

This lineage later supports attribution and economics.

## 12. Remix affordance

A user should encounter creation in context, not through creator education.

Examples:

- **Remix** on a Play;
- **Make yours** after completion;
- **Use this format** on template details;
- **Make one about [topic]** from a demand prompt.

Avoid onboarding banners explaining the creator platform.

## 13. Contribution from expertise

Do not ask users what they can teach during initial onboarding.

Contribution is triggered after evidence.

Example:

> **You know a lot about cybersecurity. Make one?**

Then:

> **What do people often get wrong about phishing?**

The user supplies the insight. Mixli can suggest suitable formats such as Guess, scenario choice, or spot-the-error.

The creator reviews and approves the resulting Play.

This gradually builds an **I CAN CONTRIBUTE** graph alongside **I WANT TO KNOW**.

## 14. Demand Board

Post-core-loop feature.

Demand Board summarizes under-served user intent without exposing personal user data.

Example:

### Marrakech

High demand:

- cheap food;
- markets;
- hotel choices;
- first-time itineraries;
- local transport.

Creator action:

**Make a Play**

### Piano

High demand:

- beginner notes;
- chord recognition;
- rhythm;
- play-back games.

Demand should be derived from:

- explicit learning interests;
- saves/searches;
- successful adjacent Plays;
- repeated feed gaps;
- user requests;
- topic/format scarcity.

## 15. Demand-to-template matching

Demand Board should recommend format as well as topic.

Example:

> Users learning piano strongly engage with audio playback.

Suggested template:

**Hear it → play it back**

This joins the topic demand graph to the interaction graph.

## 16. AI assistance

AI is a creation accelerator, not autonomous publisher.

Useful tasks:

- suggest a Play format from creator material;
- create candidate distractors;
- shorten copy;
- propose branches;
- translate;
- clean audio/image framing;
- summarize a creator-supplied source;
- generate accessibility drafts;
- suggest tags;
- detect internal contradictions.

For factual content:

```text
SOURCE → CREATOR MATERIAL → AI ASSIST → CREATOR APPROVAL → PLAY
```

Never:

```text
PROMPT → UNSOURCED FACTS → AUTO-PUBLISH
```

## 17. Factual provenance

Factual Plays require provenance appropriate to the claim.

Store:

- source URL/reference;
- source title/provider;
- retrieval/publication date where available;
- creator note if interpretation is involved;
- verification/moderation state.

Creator UI should make adding one good source easier than skipping it.

## 18. Rights and media provenance

Uploaded assets need:

- ownership/license declaration;
- source where applicable;
- automated media checks;
- moderation state;
- derivative tracking.

Creators may not publish media they are not allowed to use.

## 19. Content safety

Mixli never supports adult, erotic, or sexually explicit content.

There is no creator override or mature-content tier.

Publication validation and moderation enforce this platform-wide.

## 20. Creator quality signals

Primary signals:

- played;
- completed;
- saved;
- shared;
- replayed;
- remixed;
- hidden/reported;
- template reuse;
- downstream derivative quality.

Follower count must not become the primary quality prior.

## 21. Creator reputation

Profiles emphasize topical contribution.

Example:

**Known for**  
Piano · Travel · Architecture

**Contribution**  
42 Plays · 8 Templates

**Most remixed**  
[template cards]

Topic reputation can later derive from consistent positive performance and provenance quality.

## 22. Creator distribution

Publishing does not guarantee broad distribution.

New Plays enter a controlled candidate pool.

Distribution expands when early signals show:

- strong play-start rate;
- appropriate completion;
- saves/shares;
- low hide/report rate;
- no provenance/moderation issues;
- novelty relative to existing supply.

This protects the consumer feed from creator spam.

## 23. Template distribution

Templates have independent discovery and ranking.

A template can be valuable even when the original Play is not broadly consumed.

Template metrics:

- remix opens;
- completed remixes;
- published remixes;
- downstream qualified consumption;
- derivative diversity;
- derivative hide/report rate.

## 24. Economics

Not v1.

Future economics can reward:

- original Play consumption;
- template reuse;
- qualifying downstream remixes;
- sponsored Play creation;
- premium expert collections.

If implemented, payouts should follow qualified value, not raw impression volume alone.

## 25. Creator analytics

Minimum useful dashboard:

- Plays published;
- Played;
- Completed;
- Saved;
- Shared;
- Remixed;
- hidden/report rate;
- top topics;
- top templates.

Avoid vanity analytics that encourage spam.

## 26. Abuse controls

- rate limits for publish/remix;
- duplicate detection;
- spam similarity detection;
- report workflow;
- rights complaints;
- provenance checks;
- moderation suspension without deleting lineage;
- creator trust levels;
- no arbitrary external links inside Plays by default.

## 27. Creator API boundary

Creator tooling writes draft schema through supported APIs.

Only server-side publication can mint a published revision after validation.

Clients cannot directly mark content published or recommendation-eligible.

## 28. Moat test

The creator platform is compounding when:

1. successful Plays cause remixes;
2. successful remixes improve template discovery;
3. creators invent formats other creators reuse;
4. demand data directs supply into genuine gaps;
5. better supply improves consumer retention;
6. more consumer behavior improves demand and format signals.

If creation remains “upload a clip and add a question,” the moat is insufficient.
