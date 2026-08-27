# Mosaic — Play Runtime Specification

## 1. Purpose

The Play runtime is Mosaic's execution layer for interactive feed content.

A Play must be declarative, portable, versioned, safe, measurable, and render identically in:

- consumer app;
- creator preview;
- tests;
- future web surfaces.

Creators do not ship arbitrary application code.

## 2. Runtime contract

A Play is an immutable published revision containing:

- metadata;
- topic/learning tags;
- classification;
- media references;
- ordered/graph state definitions;
- typed inputs;
- validation logic;
- responses;
- transitions;
- provenance;
- remix/template lineage.

The runtime owns execution.

## 3. Play schema

Conceptual v1 shape:

```json
{
  "schemaVersion": 1,
  "id": "play_...",
  "revisionId": "prv_...",
  "creatorId": "usr_...",
  "templateRevisionId": "trv_...",
  "remixParentRevisionId": null,
  "format": "guess",
  "classification": "fact",
  "topics": ["travel", "croatia"],
  "learningTopics": ["european-geography"],
  "estimatedDurationSec": 20,
  "assets": [],
  "sources": [],
  "entryState": "question",
  "states": {}
}
```

Published revisions are immutable. Editing creates a new revision.

## 4. State model

Each state contains four concerns:

```text
presentation
input
validation
transition
```

Optional response effects are attached to validation outcomes.

Conceptual state:

```json
{
  "presentation": {
    "layers": []
  },
  "input": {
    "type": "single_choice",
    "options": []
  },
  "validation": {
    "type": "equals",
    "value": "dubrovnik"
  },
  "responses": {
    "correct": {},
    "incorrect": {}
  },
  "transition": {
    "correct": "reveal",
    "incorrect": "reveal"
  }
}
```

## 5. State-machine rules

- exactly one entry state;
- every referenced transition must resolve;
- terminal states are explicit;
- unreachable states are rejected at publish time;
- unbounded automatic loops are rejected;
- user-controlled repeat loops require explicit repeat limits or a terminal escape;
- swipe-away is always available outside the Play graph;
- runtime never relies on client wall-clock correctness for score integrity.

## 6. Formats vs primitives

The five product formats are authoring concepts:

- Guess;
- Choose;
- Solve;
- Play;
- Discover.

They are not separate runtimes.

All formats compile to the same primitive state graph.

## 7. Media primitives

Initial primitives:

- `text`
- `image`
- `image_sequence`
- `video_clip`
- `audio`
- `map`
- `canvas`
- `animation`
- `simple_3d`

Media is referenced through managed assets, never arbitrary remote URLs in published Plays.

Each asset stores:

- canonical ID;
- MIME/type;
- duration/dimensions where relevant;
- derivative variants;
- rights/provenance metadata;
- moderation state.

## 8. Input primitives

Initial set:

- `tap`
- `single_choice`
- `multiple_choice`
- `drag`
- `order`
- `hotspot`
- `text_short`
- `draw`
- `rhythm_tap`
- `piano_key`
- `map_point`
- `record_audio`

Primitives expose a common lifecycle:

```text
READY → ACTIVE → SUBMITTED → RESOLVED
```

## 9. Validation primitives

Supported validators should remain small and explicit:

- equals;
- set equality;
- ordered sequence;
- numeric range;
- coordinate radius;
- target region/hotspot;
- score threshold;
- pattern comparator;
- no-validation preference selection.

Complex validators should be server-defined primitives, not creator code.

## 10. Response primitives

A resolved action may trigger:

- reveal;
- text;
- image/media change;
- animation;
- sound;
- haptic;
- score update;
- explanation;
- source/provenance affordance.

Responses must be bounded and deterministic.

## 11. Transition primitives

Transitions may depend on:

- answer result;
- selected option;
- score band;
- attempt number;
- explicit creator branch;
- timer expiry.

No remote network response may dynamically alter a published Play's graph during execution except server-owned service primitives defined by schema version.

## 12. Example — travel clip Guess

```json
{
  "schemaVersion": 1,
  "format": "guess",
  "classification": "fact",
  "topics": ["travel", "croatia", "beautiful-places"],
  "learningTopics": ["geography"],
  "entryState": "guess",
  "states": {
    "guess": {
      "presentation": {
        "layers": [
          { "type": "video_clip", "assetId": "asset_dubrovnik_01" },
          { "type": "text", "value": "Where is this?" }
        ]
      },
      "input": {
        "type": "single_choice",
        "options": ["Amalfi", "Dubrovnik", "Santorini", "Valletta"]
      },
      "validation": { "type": "equals", "value": "Dubrovnik" },
      "transition": { "default": "reveal" }
    },
    "reveal": {
      "presentation": {
        "layers": [
          { "type": "text", "value": "Dubrovnik, Croatia" },
          { "type": "text", "value": "Its medieval walls run for roughly 2 km around the old city." }
        ]
      },
      "input": { "type": "tap", "label": "Done" },
      "transition": { "default": "$end" }
    }
  }
}
```

The exact fact/source must be verified by content tooling before publication.

## 13. Example — situated Choose

```json
{
  "format": "choose",
  "classification": "preference",
  "topics": ["travel", "food", "city-breaks"],
  "entryState": "choice",
  "states": {
    "choice": {
      "presentation": {
        "layers": [
          {
            "type": "text",
            "value": "Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking."
          }
        ]
      },
      "input": {
        "type": "single_choice",
        "options": ["Lisbon", "Marrakech"]
      },
      "validation": { "type": "none" },
      "transition": {
        "Lisbon": "lisbon_followup",
        "Marrakech": "marrakech_followup"
      }
    }
  }
}
```

Preference Plays record the choice without manufacturing a correct answer.

## 14. Example — piano playback

A playback Play is composed from:

1. audio presentation;
2. piano-key input;
3. ordered-sequence validation;
4. correct/incorrect response;
5. optional second attempt;
6. terminal state.

The musical interaction is still data interpreted by the runtime.

## 15. Runtime session state

Client session state includes:

- Play revision ID;
- current state;
- attempts;
- local score;
- input history required for the current Play;
- start/interaction timestamps;
- resume eligibility.

Do not persist more than required for the experience.

## 16. Resume behavior

A Play may declare:

- `restart_on_return`;
- `resume_state`;
- `non_resumable`.

Default for short Plays is `resume_state` while the feed session remains active, then restart later unless the format requires continuity.

## 17. Prefetch model

Feed response should separate:

- Play metadata/schema;
- lightweight preview assets;
- deferred heavy assets.

Runtime maintains a bounded window:

```text
previous 1 | current | next N
```

N is adaptive to network/device memory.

Audio/video should not all be prefetched blindly.

## 18. Performance constraints

- no external webviews for standard Plays;
- no arbitrary scripts;
- no per-Play package downloads;
- Play schema must parse/validate quickly;
- runtime should reuse primitive renderers;
- media decode must not block vertical swipe;
- animation should stay within device-safe frame budgets;
- inactive canvas/audio resources must be released promptly.

## 19. Accessibility

Every primitive requires an accessibility contract.

Examples:

- images require creator-provided or reviewed alt text where needed;
- audio-only factual Plays need equivalent accessible content or be marked format-incompatible for users requiring alternatives;
- drag interactions require alternate controls;
- color alone cannot encode correctness;
- motion-reduced mode disables nonessential movement;
- captions/transcripts are required where speech conveys factual content.

Accessibility metadata is part of publication validation.

## 20. Analytics hooks

Runtime emits format-independent events:

- `play_impression`
- `play_visible`
- `play_started`
- `play_action`
- `play_resolved`
- `play_completed`
- `play_dismissed`
- `play_replayed`
- `play_saved`
- `play_shared`
- `play_remix_opened`

`play_action` carries primitive-specific payload under a versioned envelope.

## 21. Schema versioning

- schema version is explicit;
- clients advertise supported versions;
- server does not send unsupported schema;
- migrations create new immutable revisions;
- old published revisions remain reproducible where possible;
- compatibility fixtures are retained in CI.

## 22. Publication validation

Before publication:

- schema valid;
- graph valid;
- assets available and moderated;
- accessibility requirements satisfied;
- factual provenance present where required;
- classification valid;
- no adult/erotic/sexually explicit content;
- no prohibited remote execution;
- estimated resource usage within limits.

## 23. Security boundary

The Play runtime is a data interpreter, not a plugin host.

Creators cannot:

- execute JavaScript;
- fetch arbitrary URLs;
- access device files/contacts/location unless a future explicitly permissioned primitive exists;
- embed remote web apps;
- bypass analytics/moderation;
- inject custom native code.

New capability ships as a reviewed runtime primitive.

## 24. Runtime success test

The runtime is successful when a new high-quality Play can be created by changing data/template slots rather than adding application code.
