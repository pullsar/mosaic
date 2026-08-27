# Mosaic — Trust, Rights & Moderation Specification

## 1. Purpose

Mosaic combines user-generated media, factual content, remixing, personalization, and eventual creator economics. Trust must therefore be built into publication and distribution rather than added after growth.

## 2. Safety baseline

Mosaic never permits:

- adult, erotic, or sexually explicit content;
- sexual services or pornography;
- exploitative sexualized depictions;
- prohibited violent/extremist/illegal content;
- malicious files or executable payloads;
- content that bypasses the declarative Play runtime.

There is no mature-content tier.

## 3. Separate rights layers

Every published object tracks rights independently for:

### Play structure

Can another creator reuse the interaction/template structure?

### Media asset

Can another creator reuse this image, clip, or audio asset?

### Text/factual contribution

Can supplied copy or source-derived material be remixed or quoted?

A Play being remixable does not imply its media is reusable.

## 4. Machine-readable remix policy

Conceptual policy:

```json
{
  "structureRemix": true,
  "mediaReuse": false,
  "textReuse": true,
  "attributionRequired": true,
  "commercialReuse": false
}
```

Inherited upstream rights cannot be broadened by a downstream creator.

## 5. Remix UX

When a creator remixes a Play:

- reusable slots remain populated;
- restricted media slots are cleared and marked required;
- attribution is carried automatically where required;
- lineage remains intact;
- the UI explains the restriction in one sentence, not legal prose.

Example:

> **Use this format. Add your own clip.**

## 6. Publication checks

Before a Play can become recommendation-eligible:

- schema/state graph valid;
- media assets ready;
- content classification valid;
- adult/sexual-content checks passed;
- required provenance present;
- rights declarations complete;
- accessibility requirements satisfied;
- creator/account state eligible;
- duplication/spam checks passed.

Publication and recommendation eligibility are separate states.

## 7. Moderation states

```text
DRAFT
READY_FOR_REVIEW
PUBLISHED_LIMITED
PUBLISHED_ELIGIBLE
DISTRIBUTION_SUSPENDED
TAKEDOWN_PENDING
REMOVED
ARCHIVED
```

Moderators can stop distribution without deleting lineage.

## 8. Reports

Consumer report reasons should remain short and specific:

- Sexual/adult content
- Violence/dangerous content
- Hate/harassment
- False/misleading factual content
- Spam/scam
- Copyright/ownership
- Other

Reporting a Play should not require explaining policy language.

## 9. Takedown model

A rights complaint may target:

- one asset;
- one Play revision;
- one template;
- a creator's repeated behavior.

If an upstream asset is removed:

- stop delivering that asset;
- suspend descendant Plays that require it;
- preserve lineage/tombstone metadata;
- do not delete unrelated descendant structure or creator work;
- allow replacement media where policy permits.

## 10. Appeals

Creators can appeal:

- moderation removal;
- rights decision;
- distribution suspension;
- account restriction.

Appeals are versioned/audited and do not silently restore recommendation eligibility before resolution.

## 11. Factual trust

Every Play is classified as one of:

- Fact
- Opinion
- Preference
- Fantasy
- Challenge

Factual assertions require provenance appropriate to risk and specificity.

The platform must never convert an opinion or preference into a fake correct answer.

## 12. Source lifecycle

Sources can become stale or unavailable.

Store:

- source reference/URL;
- source title/provider;
- publication/retrieval date where available;
- creator interpretation note where needed;
- verification status;
- last review timestamp for time-sensitive claims.

Time-sensitive factual Plays may expire from recommendation eligibility until revalidated.

## 13. Creator trust

Creator trust is not follower count.

Inputs may include:

- publication history;
- provenance quality;
- rights complaint rate;
- hide/report rate;
- confirmed policy violations;
- successful appeals;
- downstream remix quality;
- account age/verification where relevant.

Trust affects review friction and initial distribution, not truth by fiat.

## 14. Abuse-resistant engagement

Separate raw events from qualified value.

```text
RAW EVENT
  ↓
VALIDATION / FRAUD FILTERING
  ↓
QUALIFIED EVENT
  ↓
RANKING / REPUTATION / ECONOMICS
```

Discount or exclude:

- self-consumption used to inflate metrics;
- repeated automation/device patterns;
- reciprocal save/share/remix rings;
- synthetic account clusters;
- abnormal challenge funnels;
- known spam/referral abuse.

Never pay or distribute based solely on raw impression volume.

## 15. Moderation tools

Internal tooling must support:

- inspect Play revision and lineage;
- inspect asset provenance/rights;
- view reports and prior actions;
- suspend distribution immediately;
- remove/tombstone asset;
- mute creator distribution;
- reverse mistaken actions;
- audit who changed what and why.

## 16. Remote safety controls

Server-side controls must be able to disable:

- Play revision;
- template;
- creator/account;
- media asset;
- runtime primitive;
- recommendation bucket;
- experiment/feature flag;
- sharing for a Play or content class.

No App Store release should be required to stop a safety-critical feature.

## 17. Privacy boundaries

Moderation and abuse systems may use operational signals needed for integrity, but should:

- minimize raw personal identifiers;
- avoid exposing private recipient/sender data to creators;
- restrict sensitive abuse signals to internal systems;
- retain audit/legal data only as justified.

## 18. Launch gate

Controlled launch requires:

- report flow;
- distribution suspension;
- asset/Play takedown;
- rights declarations;
- remix rights enforcement;
- creator audit trail;
- adult-content rejection path;
- appeal intake;
- emergency kill switches.
