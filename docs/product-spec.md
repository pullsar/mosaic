# Mosaic — Product Specification

> **Working name:** Mosaic  
> **Positioning:** The feed you play.  
> **Core promise:** A personalized feed of tiny things to guess, choose, solve, play, watch, and discover—based on what you like and what you want to learn.

## 1. Product thesis

People already open short-form feeds when they are bored, curious, tired, waiting, or looking for entertainment.

Mosaic does not ask them to replace that habit with a routine, course, or productivity ritual. It keeps low-friction feed interaction and changes the atomic unit from passive content to a small playable experience.

**TikTok:** watch → swipe  
**Pinterest:** browse → save → swipe  
**Mosaic:** play → react → swipe

The product succeeds if users can open it with no plan and immediately find something worth doing.

## 2. Product rule

Every feed item must do at least one of these well:

- **Guess**
- **Choose**
- **Solve**
- **Play**
- **Discover**

The user can dismiss any item immediately.

There are no mandatory sessions, courses in the core feed, streak pressure, forced completion, “daily growth” framing, or adult/erotic content.

## 3. Core user job

> **Give me something interesting to do right now.**

Typical available time:

- 10–30 seconds;
- 1–3 minutes;
- occasionally 5–10 minutes.

Secondary jobs:

- entertain me;
- surprise me;
- let me test myself;
- help me learn something small;
- let me imagine or compare;
- show me something beautiful;
- help me explore an interest;
- let me contribute something I know.

## 4. Target experience

The user opens Mosaic and lands directly in the feed.

### Travel clip

*8-second aerial clip of a coastal town.*

**Where is this?**

- Amalfi
- Dubrovnik
- Santorini
- Valletta

Answer → reveal → one useful fact → swipe.

### Music

**Which piano key did you hear?**

- C
- C♯
- D

Tap → immediate feedback → swipe.

### Travel choice

**Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking.**

**Lisbon** vs **Marrakech**

Choose → tailored follow-up or swipe.

### Food

*Short kitchen clip.*

**What are they making?**

- Birria
- Shawarma
- Gyro

### Art

*Full-screen painting detail.*

**Which century?**

- 16th
- 18th
- 20th

Reveal → one cultural fact.

### Puzzle

**Move one matchstick to fix the equation.**

Manipulate directly.

### Piano

**Play this back.**

♫ ♫ ♫

Interactive keyboard.

### Faith

**A short prayer for courage**

**Pray**

Swipe if not wanted. Faith content appears only when explicitly selected or behaviorally requested.

## 5. Onboarding

Onboarding captures two different signals.

### Screen 1 — What are you into?

Visual tag cloud.

Example tags:

Travel · Food · Music · Piano · Art · Cars · Architecture · History · Nature · Football · Fashion · Technology · Faith · Puzzles · Movies · Photography · Design · Languages · Business · Science · Cooking

Actions:

- select any number;
- search;
- skip with **Surprise me**.

### Screen 2 — What do you want to learn more about?

Same broad taxonomy with deeper subtopics.

Example:

Piano · Japan · Architecture · Investing · Photography · French · Wine & Food · Astronomy · Cooking · Design

Actions:

- select any number;
- skip.

Then the feed starts immediately. No third questionnaire.

## 6. Personalization model

Mosaic learns three distinct things.

### A. Interest graph

What the user enjoys.

```text
Travel
 ├─ Mediterranean cities
 ├─ food
 ├─ architecture
 └─ beaches
```

### B. Learning graph

What the user wants to know more about.

```text
Piano
 ├─ notes
 ├─ rhythm
 └─ ear training
```

### C. Interaction graph

How the user prefers to engage.

```text
Choose       strong
Audio        strong
Visual Guess strong
Puzzle       medium
Long Video   weak
Reading      weak
```

This separation is core to the recommendation moat. Two users can share the same topic interest while preferring completely different forms of interaction.

## 7. Feed interaction

One Play fills the viewport.

**Swipe up** — next Play.  
**Tap / manipulate** — engage.  
**Back** — return to feed.  
**Save** — keep for later.  
**More** — not interested, mute topic, mute creator, report.

Swiping away is always allowed before completion.

## 8. The Play

A **Play** is the atomic content object.

Typical duration:

- 5–60 seconds;
- occasionally up to 3 minutes.

Most Plays use this state model:

```text
SETUP
  ↓
ACTION
  ↓
RESPONSE
  ↓
REVEAL
  ↓
OPTIONAL NEXT
```

The user may leave at any state.

## 9. Launch Play formats

### 9.1 Guess

One answer exists.

Examples:

- Which note is this?
- Where is this?
- Which car made this sound?
- Which century?
- Which animal is this?
- Which language are they speaking?
- Which dish is being prepared?

### 9.2 Choose

There may be no objectively correct answer. Used for taste, fantasy, preference, comparison, and recommendation learning.

Examples:

- Which restaurant would you book?
- Which four-day getaway fits this budget?
- Which living room would you keep?
- Which beach would you wake up on?
- Which outfit works better?
- Which city suits this traveller?

#### Choice design rule

Avoid generic comparisons when a situation can make the choice meaningful.

Weak:

> Lisbon or Marrakech?

Strong:

> **Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking. Lisbon or Marrakech?**

Choices should usually contain a constraint, desire, role, budget, occasion, or scenario.

### 9.3 Solve

Self-contained games:

- logic;
- spatial manipulation;
- word games;
- pattern recognition;
- visual riddles;
- route finding;
- sequence completion.

### 9.4 Play

Direct manipulation:

- play a melody back;
- tap a rhythm;
- place a city on a map;
- drag objects into order;
- draw a missing shape;
- assemble a simple structure;
- pronounce and compare a phrase.

This is the strongest differentiator from passive feeds.

### 9.5 Discover

Used when forcing a game would reduce the experience.

Examples:

- short cultural scene;
- beautiful place;
- archival footage;
- artwork;
- architecture;
- music;
- wildlife;
- prayer;
- unusual object;
- historical moment.

Natural actions can include **Where is this?**, **Hear it**, **Look closer**, **What happened next?**, **Pray**, **Reveal**, or **Explore**. Do not manufacture interaction for its own sake.

## 10. Media primitives

A Play format is separate from its media.

Supported media:

- image;
- image sequence;
- short video clip;
- audio;
- map;
- text;
- animation;
- simple 3D;
- interactive canvas.

### Short clips

Short clips are a first-class media primitive.

Examples:

**Where is this?** — beautiful travel footage + location options.  
**Which dish is this?** — cooking clip + options.  
**Which dance tradition?** — cultural clip + options.  
**What happens next?** — short scene + prediction.  
**Which instrument enters next?** — music clip + answer.

Video remains useful, but the product does not become a passive video feed.

## 11. Launch content areas

### Travel + Food

Destinations, restaurants, local food, budgets, neighborhoods, cultural behavior, landmarks, travel clips.

### Music

Piano, ear training, instruments, melody, rhythm, music history.

### Puzzles

Logic, spatial, visual, words, patterns.

### Art + Culture

Painting, architecture, fashion, design, historical objects, cultural traditions.

### Curiosity

Science, nature, technology, everyday phenomena.

### Faith + Reflection

Optional: prayer, scripture, sacred art, religious history, reflection. No faith content is forced on users who do not select or engage with it.

## 12. Content safety

Mosaic never offers adult, erotic, or sexually explicit content. There is no future adult-content mode.

Allowed aesthetic content includes art, fashion, architecture, people, landscapes, design, culture, and nature. All content follows broad mainstream consumer-app safety standards.

## 13. Feed ranking

The ranking system should not optimize primarily for watch time.

Positive signals:

- interaction started;
- completion;
- replay;
- deliberate second round;
- save;
- share;
- follow-up choice;
- topic exploration;
- explicit like;
- remix;
- return to an item.

Negative signals:

- immediate swipe;
- repeated topic dismissal;
- abandonment after engagement;
- mute;
- hide;
- report;
- repeated format fatigue.

Dwell time is evidence, not the objective.

## 14. Discovery balance

The feed must preserve serendipity.

Recommendation sources:

- **Known** — established interests;
- **Adjacent** — related interests;
- **Wildcard** — unrelated candidates.

Exact ratios are tuned experimentally.

Goal:

> **I didn't know I liked that.**

## 15. Navigation

Launch navigation:

**Play · Saved · Create · Me**

No dashboard, feed/category maze, or course browser in v1.

## 16. Creation is the supply moat

The consumer feed is copyable. The creator system must be much harder to copy.

Mosaic should become the easiest place to create a tiny interactive experience.

The creator moat consists of:

1. reusable interaction primitives;
2. templates;
3. remixing;
4. creator distribution;
5. template lineage;
6. creator reputation;
7. demand signals;
8. eventual economics.

## 17. Creation levels

### 17.1 Remix

Every eligible Play exposes **Remix**.

Tap it. Editable slots appear.

Example original:

**Which piano key is this?**

Creator replaces:

- audio;
- options;
- correct answer;
- reveal.

Publish.

Target: a good remix can be created in under one minute. No layout work required.

### 17.2 Quick Create

Tap **Create**.

First choice:

**Guess · Choose · Solve · Play · Discover**

Only required fields are shown.

Example — Choose:

**Situation**

`Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking.`

**Option A** — Lisbon [media]  
**Option B** — Marrakech [media]

**After choice** — optional response or follow-up.

**Publish**

No design tool is exposed unless requested.

### 17.3 Studio

Power creators can build reusable Play structures using a constrained interaction grammar.

**Media:** Image · Clip · Audio · Text · Map · 3D  
**Input:** Tap · Choose · Type · Drag · Draw · Play note · Record sound  
**Logic:** Correct · Compare · Branch · Score · Sequence · Timer  
**Response:** Reveal · Animate · Sound · Haptic · Explanation  
**Flow:** Next state · End · Another Play

Example:

```text
Audio
  ↓
3-choice answer
  ↓
Correct / incorrect response
  ↓
Keyboard
  ↓
Play-back challenge
```

The creator can save the structure as a template.

## 18. Templates

Templates are first-class assets containing interaction structure, transitions, layout, animation, scoring behavior, and editable slots.

They are topic-independent where possible.

**Which sounds better?** can support piano, cars, birds, languages, singers, speakers, or guitars.

**Pick your getaway** can support thousands of travel scenarios.

## 19. Remix lineage

Every derivative retains lineage.

```text
Template
   ↓
Creator Play
   ↓
Remix
   ↓
Remix
```

Mosaic records original creator, template creator, derivative creator, reuse count, and performance. This makes format invention valuable.

## 20. Creator flywheel

```text
PLAY
 ↓
"I could make this about X"
 ↓
REMIX
 ↓
PUBLISH
 ↓
DISTRIBUTION
 ↓
OTHERS PLAY
 ↓
SOME REMIX
 ↓
FORMAT SPREADS
```

The goal is to make creating an interactive Play feel as natural as using a short-video template.

## 21. Giving / contribution

Do not ask new users what they can teach during onboarding.

Contribution appears after Mosaic has evidence of knowledge or interest.

Example:

> **You know a lot about cybersecurity. Make one?**

Prompt:

> **What do people often get wrong about phishing?**

The user contributes the insight. Mosaic helps turn it into a Play. The creator approves before publication.

This creates two long-term graphs—**I WANT TO KNOW** and **I CAN CONTRIBUTE**—without burdening the initial experience.

## 22. Demand Board

The creator system should eventually show unmet demand.

Examples:

**Travel:** cheap food, first-time itineraries, hotel choices, markets, transport.  
**Music:** beginner piano, identify chords, Afrobeats rhythm, vocal range.

Each demand item exposes **Make a Play**.

This turns consumer behavior into creator guidance. Demand Board is post-core-loop scope.

## 23. AI in creation

AI assists production but does not become the product's author.

Allowed uses:

- suggest suitable Play formats;
- crop or clean media;
- generate candidate distractors;
- turn supplied material into interaction drafts;
- suggest branches;
- translate;
- summarize supplied sources;
- create supporting animation;
- check simple inconsistencies.

For factual content:

> **source → creator → Play**

not:

> **prompt → generated trivia → feed**

The creator owns the final assertion.

## 24. Factual quality

Every Play is classified as one of:

- **Fact**
- **Opinion**
- **Preference**
- **Fantasy**
- **Challenge**

Factual Plays can carry sources. Preference Plays do not pretend there is one correct answer. This distinction is mandatory in authoring and moderation.

## 25. Creator reputation

Creator identity should emphasize usefulness over celebrity.

Profile examples:

**Known for:** Travel · Piano · Architecture  
**Contributions:** 42 Plays · 8 Templates  
**Most remixed:** [templates]

Primary creator metrics:

- played;
- completed;
- saved;
- shared;
- remixed.

Follower count may exist later but should not dominate discovery.

## 26. Social

V1 social is lightweight.

A Play can be sent with prompts such as:

- **Can you beat me?**
- **Which would you choose?**
- **Guess before I tell you mine.**

No public comments, full messaging system, or separate social feed in v1.

## 27. Saved

Saving is lightweight. Automatic collections can include Travel, Restaurants, Music, Art, and Things to try. Users can create or rename collections. Saved content is not presented as homework.

## 28. Notifications

Sparse and actionable.

Good:

- **Sam challenged you to this.**
- **A new piano Play from a creator you saved.**

Avoid guilt, streak pressure, fake urgency, and generic retention copy.

## 29. Visual system

The content owns the screen.

Principles:

- edge-to-edge media;
- minimal chrome;
- clear direct manipulation;
- subtle haptics;
- motion explains state;
- readable in one glance;
- interactions close to the object being manipulated;
- controls appear only when needed.

Copy must be functional.

Prefer **Which sounds warmer?** over explanatory setup copy. Prefer **Play it back.** over instructions that restate the interaction.

## 30. Audio behavior

Audio never starts loudly by surprise. Default: **Tap to hear**. If the user consistently enables sound, Mosaic may preserve the preference.

## 31. Initial inventory

Private beta target: **500–1,000 excellent Plays**.

Do not launch with mass-generated filler.

The initial inventory must demonstrate multiple topics, all five Play formats, image/audio/clip/interactive media, and several strong reusable templates.

## 32. Creator seeding

Invite creators with actual subject competence: musicians, travel enthusiasts, chefs, puzzle designers, photographers, museum/culture creators, teachers, and specialist hobbyists.

Initial creator goal: discover formats worth remixing, not follower acquisition.

## 33. Core data model

### Play

```text
id
creator_id
template_id
topics[]
learning_topics[]
format
classification
states[]
assets[]
estimated_duration
sources[]
content_rating
remix_parent_id
```

### State

```text
presentation
input
validation
response
transition
```

Normal Plays run inside Mosaic's runtime. Creators do not ship arbitrary code.

## 34. Core services

```text
Feed
 ├─ ranking
 ├─ interest graph
 ├─ learning graph
 └─ interaction graph

Play Runtime
 ├─ renderer
 ├─ state machine
 ├─ input handlers
 └─ media/audio engine

Creator
 ├─ Remix
 ├─ Quick Create
 ├─ Studio
 ├─ Templates
 └─ Demand Board

Content
 ├─ Plays
 ├─ assets
 ├─ provenance
 └─ moderation

Analytics
 ├─ impressions
 ├─ interactions
 ├─ completion
 ├─ dismissals
 ├─ saves
 ├─ shares
 └─ remix lineage
```

## 35. Performance requirements

The feed must feel immediate.

Requirements:

- next Play prefetched;
- swipe never waits on network;
- visual shell renders immediately;
- audio prefetched only when likely;
- heavy modules lazy-loaded;
- interaction state persisted locally where useful.

A Play must never feel like opening a mini website.

## 36. Success metrics

### Consumer primary

**Played impressions / eligible impressions**

Supporting:

- D1 / D7 retention;
- meaningful actions per session;
- saves;
- shares;
- repeat plays;
- topic discovery;
- learning-topic engagement;
- interaction-format affinity;
- voluntary return rate.

Monitor rapid-swipe fatigue, repeated topic rejection, excessively long sessions, and reports.

### Creator primary

**Qualified Plays consumed from community supply**

Supporting:

- create → publish conversion;
- median creation time;
- second-creation rate;
- remix rate;
- template reuse;
- creator D7 / D30 retention;
- share of feed supplied by creators.

## 37. Validation experiments

### A. Feed vs menu

Same content. Test whether swipe discovery increases engagement.

### B. Generic vs situated choice

A: **Lisbon or Marrakech?**

B: **Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking. Lisbon or Marrakech?**

Measure play rate and follow-through.

### C. Interest-only vs interest + learning graph

Measure whether explicit learning intent materially improves recommendations.

### D. Topic-only vs topic + interaction graph

Measure whether interaction-style personalization improves engagement.

### E. Blank creation vs remix

Measure publication rate and time.

### F. Human-curated vs AI-heavy supply

Measure completion, saves, repeats, hides, and reports. Do not assume cheaper supply is better supply.

## 38. Explicitly out of v1

No:

- courses;
- streaks;
- public comments;
- livestreaming;
- generic creator video feed;
- long-form articles;
- marketplace;
- subscriptions;
- elaborate avatars;
- groups;
- public leaderboards;
- mandatory routines;
- adult content;
- full messaging;
- “what can you teach?” onboarding;
- AI-generated content firehose.

## 39. Expansion path

### Phase 2

- Demand Board;
- advanced Studio;
- creator reputation by topic;
- collaborative Plays;
- user challenges;
- deeper contribution prompts;
- template marketplace.

### Phase 3

- creator payouts;
- sponsored Plays;
- expert collections;
- multiplayer;
- local/contextual Plays;
- institutional publishers.

## 40. Monetization principle

Commercial content must itself be worth playing.

Weak: **Visit Morocco.**  
Strong: **£600. Four nights. Which Moroccan city fits you?**

Weak: **Buy these headphones.**  
Strong: **Can you hear the difference?**

Ads become participation, not interruption.

## 41. Defensible flywheel

```text
MORE PLAY
   ↓
BETTER INTEREST + LEARNING + INTERACTION GRAPHS
   ↓
BETTER DEMAND SIGNALS
   ↓
CREATORS SEE WHAT PEOPLE WANT
   ↓
BETTER PLAYS + TEMPLATES
   ↓
MORE REMIXING
   ↓
MORE SUPPLY
   ↓
BETTER FEED
```

The long-term moat is:

1. interaction runtime;
2. template library;
3. creator tooling;
4. remix lineage;
5. creator demand data;
6. interest graph;
7. learning graph;
8. interaction graph;
9. accumulated high-quality interactive supply.

## 42. Launch message

# The feed you play.

**Guess things. Choose things. Solve things. Discover things you like.**

Swipe if you don't.

## 43. Product test

A v1 feature belongs only if it strengthens one of these loops:

```text
FIND → PLAY → REACT → SWIPE
```

or:

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

Everything else waits.
