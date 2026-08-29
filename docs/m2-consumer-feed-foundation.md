# M2 consumer feed foundation

This tranche establishes the server/data boundary for issue #4 before the Flutter onboarding/feed surface is introduced.

## Implemented here

- separate anonymous `interest` and `learning` topic selections;
- explicit immutable Play-revision topic roles and recommendation eligibility;
- bounded topic search and preference APIs;
- one capability parser shared by direct revision delivery and feed selection;
- capability-compatible feed windows persisted for deterministic cursor continuation;
- interpretable `m2-rules-v1` ranking with separate feature contributions;
- weak single-dismissal evidence, progressively stronger repeated dismissal, independent More Like This affinity, topic-mute exclusion hooks and a small wildcard exploration guarantee;
- deterministic compatible curated fallback if ranking logic/configuration fails;
- 24-hour cursor validity, actor/capability fencing and bounded `SKIP LOCKED` cleanup of expired decisions;
- PostgreSQL migration rollback/reapply coverage and seed fixture materialization.

## Intentionally not in this tranche

- Flutter onboarding screens and topic tiles;
- cross-platform feed HTTP client and vertical pager/prefetch window;
- Save/Share/More Like This/Not interested/mute/report UI actions;
- behavioral signal materialization from interaction events into the live profile;
- Play/intent search beyond the topic catalog;
- learned ranking, pgvector or semantic retrieval.

Those remain in issue #4. The next tranche should consume this API through one client-side consumer repository, reusing #14 local preferences/feed resume and #46 event delivery rather than creating parallel persistence or analytics paths.
