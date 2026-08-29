# Mixli — Identity & Account Lifecycle Specification

## 1. Purpose

Mixli should provide value before asking for registration.

Identity starts anonymous and becomes durable only when the user needs sync, creation, or social continuity.

## 2. Actor model

Every session has an `actor_id`.

An actor may be:

- anonymous device/session actor;
- registered user;
- merged former-anonymous actor linked to a registered user.

Product events reference `actor_id`; account-specific systems may also resolve `user_id`.

## 3. Anonymous-first flow

```text
APP INSTALL / WEB PLAY
        ↓
ANONYMOUS ACTOR
        ↓
PLAY / ONBOARD / LEARN
        ↓
OPTIONAL ACCOUNT CREATION
        ↓
MERGE ANONYMOUS STATE
```

No login wall before the first Play.

## 4. Anonymous capabilities

Anonymous users may:

- play public Plays;
- select interests;
- select learning interests;
- build short-lived recommendation signals;
- dismiss/mute locally;
- participate in public challenge links;
- save locally where platform storage permits.

## 5. Account-required capabilities

Registration is required for:

- durable cross-device saves;
- creation/publishing;
- following creators;
- durable challenge history;
- creator reputation;
- moderation appeals tied to a creator account;
- payouts if introduced later.

Registration should be requested in context, not as a generic startup requirement.

## 6. Merge behavior

When an anonymous actor registers or signs in:

- preserve interest selections;
- preserve learning selections;
- preserve eligible saves;
- preserve recommendation history subject to retention policy;
- preserve challenge outcomes where safe;
- deduplicate against existing account state;
- never duplicate creator actions or qualified consumption.

The merge must be idempotent.

## 7. Existing-account sign-in

If an anonymous actor signs into an existing account, server policy resolves conflicts.

Rules:

- explicit account settings win over inferred anonymous settings;
- new anonymous positive signals may be merged with bounded weight;
- existing mutes/blocks remain authoritative;
- local unsynced saves may be offered for merge;
- no private account data is exposed before authentication completes.

## 8. Device/session identity

Do not treat device ID as person identity.

Maintain separate concepts for:

- actor;
- session;
- device installation;
- account.

This is required for attribution, abuse detection, privacy, and multi-device use.

## 9. Recommendation reset

Users must be able to:

- remove an interest;
- remove a learning interest;
- mute a topic;
- reset inferred recommendation signals;
- clear local anonymous history where applicable.

Reset behavior should be explicit and auditable.

## 10. Deletion

Account deletion must define behavior for:

- profile;
- saves;
- recommendation data;
- Plays;
- templates;
- remix descendants;
- moderation records required for legal/safety retention;
- aggregated analytics that are no longer user-identifiable.

Published content with descendants should be tombstoned/de-attributed according to rights policy rather than corrupting lineage.

## 11. Privacy

- do not infer or persist sensitive attributes merely because interests correlate with them;
- separate operational identity from analytics exports where possible;
- use minimum retention for raw identifiers;
- expose clear controls for recommendation signals;
- anonymous does not mean unprotected: apply the same safety and abuse controls.

## 12. Authentication implementation

Authentication provider is replaceable.

Support a narrow interface for:

- sign in;
- sign out;
- token refresh;
- account linking;
- actor merge;
- account deletion request.

Avoid coupling Play/runtime code to auth-provider SDKs.

## 13. Success test

A first-time recipient should be able to open and enjoy Mixli immediately, while a returning registered user receives durable personalization without losing or duplicating their earlier anonymous behavior.
