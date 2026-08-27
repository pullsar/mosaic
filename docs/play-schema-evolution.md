# Mosaic Play Schema Evolution

## Purpose

Published Play revisions are immutable and may outlive the client version that created them. Schema evolution must therefore be explicit, capability-aware, and safe for old clients.

## Current support

- Current schema: **v1**
- Supported schemas: **v1**
- Pinned compatibility fixture: `packages/play_schema/fixtures/compat/v1_baseline_guess.json`
- Language-neutral contract: `contracts/play-v1.schema.json`
- Client capability contract: `contracts/client-capabilities-v1.schema.json`

`PlaySchemaSupport` is the Dart source for the currently supported schema-version set. Server implementations must enforce the same set through conformance tests rather than duplicating an untested constant.

## Capability envelope

A client reports the runtime it can actually execute:

```json
{
  "schemaVersions": [1],
  "presentationTypes": ["text", "video_clip"],
  "inputTypes": ["tap", "single_choice"],
  "validatorTypes": ["none", "equals"],
  "platformFlags": []
}
```

The server may only recommend/deliver a Play when all required capabilities are satisfied.

Capability matching occurs before typed decoding. This is required so a future primitive can be skipped safely by an older client instead of failing while parsing an unknown enum value.

## Additive changes inside a schema version

The following may be added without incrementing `schemaVersion` when existing semantics do not change:

- optional top-level fields;
- optional state/layer/input metadata;
- new presentation primitive IDs;
- new input primitive IDs;
- new validator primitive IDs;
- new optional platform flags.

New primitive IDs are **not** implicitly executable by clients that understand the schema version. They require explicit capability support.

Unknown optional fields must be ignored by existing readers unless a field is explicitly declared as required by a capability contract.

## Changes requiring a new schema version

Increment `schemaVersion` when a change alters existing wire meaning or required structure, including:

- removing or renaming a required field;
- changing the meaning/type of an existing field;
- changing transition semantics;
- changing identity/revision semantics;
- changing how an existing primitive ID is interpreted incompatibly;
- making a previously optional field mandatory for all Plays.

Do not repurpose an existing primitive ID with incompatible semantics. Introduce a new ID or schema version.

## Server delivery rule

Before a Play reaches a feed response, the server must evaluate:

1. schema version supported by client;
2. every presentation type supported;
3. every input type supported;
4. every validator type supported;
5. every `requiredPlatformFlags` value supported.

If any requirement is absent, the candidate is ineligible for that client.

The client repeats the raw compatibility check defensively before typed decode. Server filtering is not a substitute for client fail-closed behavior.

## Unsupported and malformed behavior

Clients distinguish:

- `compatible` — safe to decode/execute;
- `unsupportedSchema` — valid-looking Play for another schema generation;
- `unsupportedPrimitive` — schema understood, runtime capability missing;
- `malformed` — required compatibility structure cannot be inspected or typed decoding fails.

Unsupported/malformed Plays never crash or block the feed. They are skipped or replaced by a safe fallback and emit diagnostic telemetry without authored sensitive payloads.

## Compatibility fixtures

Every supported schema version keeps at least one pinned fixture under:

`packages/play_schema/fixtures/compat/`

Rules:

- fixture content is immutable except to correct an invalid historical fixture;
- current Dart tests must continue to parse/validate supported fixtures;
- future server implementations run the same fixtures;
- adding a new primitive must not break older supported fixtures;
- introducing schema v2 requires a v2 fixture while retaining v1 fixtures for the duration of v1 support.

## Deprecation window

A supported schema version may be removed only after all of the following:

1. a successor schema has shipped in stable clients;
2. new publication into the old schema has stopped;
3. server telemetry shows the old schema is below **0.5% of eligible Play deliveries for 30 consecutive days**;
4. at least **180 days** have passed since the successor schema first shipped broadly;
5. affected immutable Plays have a migration/archive strategy;
6. removal is covered by a feature/config rollback path and release note.

Emergency safety removal may override the window, but must preserve a tombstone/fallback rather than crash old clients.

## CI contract

Changes to schema/capability code must verify:

- current reference fixtures;
- every pinned compatibility fixture;
- unknown optional-field tolerance;
- unsupported future schema behavior;
- unsupported future primitive behavior;
- malformed raw input behavior;
- capability-envelope round trip;
- JSON contract artifacts remain valid JSON.

## Non-goal

Capability negotiation is compatibility infrastructure, not permission or trust. A client claiming support for a capability does not bypass moderation, safety, rights, account, or distribution policy.
