# Mosaic — Growth & Sharing Specification

## 1. Purpose

Mosaic should spread through the thing people already enjoy using: the Play.

The growth loop is:

```text
PLAY
  ↓
SHARE / CHALLENGE
  ↓
RECIPIENT OPENS LINK
  ↓
PLAY WORKS IMMEDIATELY
  ↓
RESULT / RESPONSE
  ↓
ANOTHER PLAY OR APP INSTALL
```

A shared link must never be a marketing page that hides the Play behind an install wall.

## 2. Viral object

The atomic shared object is an immutable Play revision plus optional challenge context.

Examples:

- **Can you beat me?**
- **Which would you choose?**
- **Guess before you see mine.**
- **I got 2/3. Your turn.**

The recipient should understand the interaction before learning anything about Mosaic.

## 3. Web Play requirement

A public, share-eligible Play must render in a lightweight web runtime without requiring an account or app installation.

Required behavior:

- open from a normal HTTPS link;
- render the same published Play revision as native;
- preserve answer/reveal semantics;
- support image, short clip, choice, puzzle, and basic audio Plays at launch;
- degrade unsupported native-only primitives explicitly rather than silently changing the Play;
- record anonymous outcome events;
- offer **Play another** and **Get Mosaic** only after the recipient has received value.

The web runtime uses the same schema and validation contract as native. It must not become a second content model.

## 4. Challenge context

A share may attach bounded context outside the immutable Play revision:

```text
challenge_id
sender_actor_id
sender_result_summary
sender_choice_hash / reveal policy
created_at
expires_at (optional)
```

Challenge context cannot modify the Play graph or factual content.

Examples:

### Competitive

> Chibueze solved this in 18s. Beat it.

### Preference

> Pick yours before seeing mine.

The sender's answer remains hidden until the recipient submits.

### Collaborative

Later:

> We both picked Lisbon. Try the next one.

## 5. Share surfaces

Launch share surfaces:

- native system share sheet;
- copy link;
- direct WhatsApp/message intents where supported;
- challenge after a completed Play;
- contextual **Send** from Play actions.

Do not build a Mosaic messaging system for v1.

## 6. Deep-link behavior

One canonical Play URL resolves across:

```text
installed app → native Play
not installed → web Play
```

Deferred deep-link attribution may be added through a provider later, but Mosaic must own the canonical URL and link data model.

Provider integration is behind a `DeepLinkProvider` abstraction.

## 7. Anonymous recipients

Recipients can:

- play;
- answer;
- compare results;
- play another public Play;
- begin interest onboarding;

without registering.

Account creation is requested only when durable identity is useful, such as saving across devices, creating, following, or maintaining challenge history.

## 8. Share metadata

Each share link should provide useful Open Graph/social preview metadata:

- concise prompt;
- safe preview image where appropriate;
- format/topic hint;
- creator attribution where useful;
- no answer leakage;
- no sensitive sender data.

A quiz preview must not reveal the correct answer.

## 9. Growth events

Required events:

- `share_opened`
- `share_link_created`
- `share_target_selected`
- `shared_play_opened`
- `shared_play_started`
- `shared_play_completed`
- `challenge_created`
- `challenge_completed`
- `shared_play_next_started`
- `shared_play_install_clicked`
- `shared_play_signup_started`
- `shared_play_signup_completed`

Attribution must distinguish sender, recipient session, Play revision, and link/challenge ID without exposing one user's private behavior to another.

## 10. Growth metrics

Primary:

**Qualified recipient Plays per share.**

Supporting:

- share rate by Play format;
- share-open rate;
- recipient start rate;
- recipient completion rate;
- second-Play rate;
- install/signup conversion after value;
- challenge response rate;
- sender repeat-sharing rate.

Do not optimize link clicks if recipients do not actually play.

## 11. Abuse controls

- signed/unguessable challenge identifiers;
- rate limits on link creation;
- spam/automation suppression;
- no arbitrary creator-controlled redirect URLs;
- revoked or moderated Plays stop resolving to playable content;
- private/unlisted Plays obey visibility policy;
- challenge result summaries are server-derived where integrity matters.

## 12. Launch gate

Controlled beta is not growth-ready until:

- a supported Play can be shared from native;
- the recipient can complete it on mobile web without installing;
- challenge/reveal behavior is deterministic;
- analytics connect share → recipient Play → next action;
- moderation/revocation propagates to shared links quickly.
