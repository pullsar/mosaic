# Continuous game rounds — 11 September 2026

Family games no longer require an authored Done acknowledgement followed by
Replay. The app recognizes a scored transition into a final, unvalidated tap
acknowledgement. The authored reveal stays intact; the app displays the session's
solved-round count immediately and advances after a 1,000 ms result beat when a
different round is ready. Final incorrect results receive 1,600 ms. Incorrect
attempts with an authored retry remain immediately playable.

## Ownership and feedback

- The immutable Play and deterministic engine are unchanged. The attempt owner
  counts completion once, starts a new attempt for a successor, and fences old
  handlers. Familiar rounds use practice telemetry. The 64-entry familiarity set
  describes this session only, not a cognitive ability metric.
- One active host holds one prepared successor and one cancellable result timer.
  Swiping away, covering the route, backgrounding, and disposal invalidate pending
  callbacks. Returning to a result requires Next round. There is no retry loop.
- The result uses a short scale response, a light native haptic, and an optional
  system confirmation sound. Effects require the existing Effects preference and
  an unmuted master setting. Missing platform feedback is nonfatal. This is not
  a completed theme-specific sound library or measured touch-to-audio latency.
  Play buttons suppress their native click so it cannot double the scoring sound
  or bypass the Effects preference.
- Reduced motion removes the scale response. Accessible navigation holds the
  result. Pause and Next round remain available; 200% text at 320 px is covered.
- Save, family controls and Share receive the newly displayed document. Subsequent
  round telemetry owns that revision rather than inheriting the original feed
  revision. Already-published or shared revisions are never rerolled in place.

## Supply contract

`POST /v1/plays/:playId/revisions/:revisionId/next-round` accepts the existing
capability envelope and returns one compatible, different Play from the exact
published family revision. Candidates must be eligible catalog entries; suspended
and unpublished candidates are excluded. Selection cycles in stable Play-ID order
within the finite reviewed pool. At most 64 candidates are considered. A 204 means
there is no compatible successor. Invalid or unavailable responses retain the
result with an explicit retry; they never silently restart the same answer.

This is fresh reviewed-round delivery, not on-device procedural generation.
Generated drafts still require the existing independent checks and publication
review before entering the pool. A larger published family supplies more variety.
Legacy Plays without a family reference retain their authored one-off flow.

## Verification and rollout

Focused coverage includes the no-Done loop, one-time scoring, stale input,
late supply, failed supply, accessible navigation, small-screen large text,
optional sound, modal pause, and the real app's next-round Share identity.
API route tests check distinct compatible rounds and unavailable source revisions.
The catalog PostgreSQL test additionally checks eligible same-family candidates;
it requires the disposable CI database and is skipped without DATABASE_URL.

The app and API changes must ship together with the current family-tagged catalog.
The connected phone's live API still served older revision-2 starters during the
visual review. An APK installation alone cannot enable this new supply endpoint
or publish those family documents. Physical loop pacing and sound-route testing
remain release acceptance work after that deployment.
