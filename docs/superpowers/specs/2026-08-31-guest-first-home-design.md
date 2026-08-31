# Mixli Guest-First Home Design

## Objective

Make the first visit feel like opening a premium short-form discovery product: content appears immediately, one Play owns the viewport, and registration is requested only after the visitor has received value.

This design supersedes the startup-order requirement in `docs/experience-design-spec.md` that places two preference screens before the feed. The preference model remains valid, but preference collection moves out of the startup gate.

## Evidence and root cause

The production failure is not only visual:

- the web release is built without `MOSAIC_API_BASE_URL`, so `ConsumerApiClient` and managed asset delivery are disabled;
- the production database has zero topics, Plays, revisions, feed catalog entries, and media assets;
- the current first-run gate therefore owns the whole viewport and shows `Topics unavailable`;
- account binding is intentionally reserved and returns `501 account_auth_not_configured`.

The fix must connect the client, provide an idempotent starter catalog, remove mandatory onboarding, and avoid pretending account creation works before an authentication provider exists.

## Approaches considered

### 1. Guest-first live feed — selected

Open directly into the full-screen feed. Ask for registration after five distinct Play impressions or dismissals. Keep the prompt dismissible and preserve anonymous progress.

This provides value before registration, matches Mixli's anonymous actor model, and lets the product explain itself through interaction.

### 2. Feed with interest chips on top

Show a playable background with an interest picker layered over it. This may improve cold-start ranking, but it divides attention and still makes the first visit feel like setup.

### 3. Editorial landing montage

Show a polished static preview before entering the feed. This is easy to art-direct but adds another page and demonstrates marketing rather than the product.

## Experience design

### Entry

After the existing local runtime boot completes, every anonymous visitor enters the default feed. No topic selection, login wall, walkthrough, or explanatory modal appears first.

The feed shell uses the existing Mixli visual language:

- dark cinematic surface;
- one Play fills the viewport;
- quiet wordmark and `For You` label at the top;
- search remains available but visually secondary;
- prompt and topic metadata sit near the lower safe area;
- action controls remain compact and thumb-reachable;
- no glass blur, ambient animation, or decorative performance cost.

The first page should render useful structure immediately while richer assets resolve. Loading must not expose a blank scaffold.

### Starter catalog

Production receives a versioned, idempotent starter catalog with at least six compatible Plays. The opening window includes visibly different interactions such as single choice, tap, and drag. Every starter Play must be media-complete: it may use registered canvas assets or dependency-free text/layout, but it cannot reference an unavailable image, video, or audio asset.

The catalog is deterministic and safe to rerun. It only upserts its owned starter records; it never deletes creator or operator content. Deployment verifies that eligible catalog content exists before switching traffic.

### Progressive registration prompt

A local guest-engagement controller observes distinct visible Plays. The first registration prompt becomes eligible after five distinct Plays have been viewed or dismissed. Retries, rebuilds, and repeated visibility of the same revision do not increase the count.

The prompt is a bottom sheet rather than a page replacement:

- title: `Your Mixli is getting good`;
- message: `Keep this feed and your progress.`;
- primary action: `Join Mixli`;
- secondary action: `Not now`;
- swipe/feed state remains intact behind the sheet.

Dismissal is persisted locally. The prompt does not reappear during the same session and observes a seven-day cooldown. Registration remains contextual for account-required actions such as cross-device saves and creation.

Because authenticated account binding is not configured, the initial `Join Mixli` action must be honest. It opens a branded early-access registration surface that explains accounts are opening soon and allows the visitor to return to the feed. It must not claim that an account or durable cloud state was created. A real authentication provider and anonymous-to-user merge remain a separate security-sensitive milestone behind the existing narrow auth boundary.

## Component boundaries

### `GuestHome`

Composes the feed, quiet navigation chrome, and progressive prompt. It does not own transport, ranking, media resolution, or authentication.

### `GuestEngagementController`

Accepts canonical feed events, deduplicates by request/revision identity, persists prompt state, and exposes whether the prompt is eligible. It contains no widget or network logic.

### `GuestSignupPrompt`

Owns only the bottom-sheet presentation and early-access transition. It receives callbacks for primary action and dismissal.

### Production starter catalog

Lives in an explicit production bootstrap module rather than a development-only fixture command. It uses the existing immutable Play schema and repository tables. The deployment runner applies it after migrations and before candidate readiness checks.

### Build configuration

The server CI build passes an explicit HTTPS API origin through `--dart-define=MOSAIC_API_BASE_URL=...`. The value has a production default of `https://api.mixli.app/` and remains overrideable for other environments. A CI contract verifies the define is present.

## Data flow

1. The browser creates or restores its anonymous actor credential.
2. `GuestHome` mounts the feed immediately.
3. The feed registers the anonymous actor and requests a server-ranked page.
4. The server returns eligible starter or creator Plays.
5. Canonical visibility and dismissal events flow to telemetry and `GuestEngagementController`.
6. At the fifth distinct Play, the controller makes the prompt eligible.
7. The sheet appears after the current interaction settles; it never interrupts direct manipulation.
8. Dismissal state and cooldown remain local until real account authentication exists.

## Failure handling

- If live feed loading fails, show recovered cached Plays first.
- If no cache exists, show a branded retry surface with a clear action, not onboarding.
- If the starter catalog is empty, deployment fails before traffic switches.
- If managed media is unavailable, only media-complete dependency-free starter content may be used as fallback.
- If early-access registration is unavailable, keep the visitor in the feed and show a concise retryable message.
- No failure may erase the anonymous actor, local progress, or current feed position.

## Tests

Tests are written and observed failing before production changes.

- first launch renders the feed and never renders `What are you into?`;
- five distinct Play views make the sign-up prompt eligible;
- duplicate visibility, rebuilds, and retries do not increment eligibility;
- `Not now` dismisses the sheet and persists the cooldown;
- the prompt waits until direct manipulation settles;
- offline/retry state remains a feed surface rather than onboarding;
- production web build includes the API origin define;
- production bootstrap is idempotent and preserves unrelated content;
- deployment refuses to switch with an empty eligible catalog;
- starter Plays pass schema/capability validation and reference only registered assets;
- server CI, Flutter analysis/tests, API tests, production build, and post-deploy verification pass on the server.

## Acceptance criteria

- A clean browser opens directly onto an interactive Play.
- The first feed window contains at least two visibly different interaction types.
- No first-run dependency on the topic endpoint remains.
- The registration prompt appears only after five distinct Plays and is dismissible.
- No UI claims successful account creation while authentication is unconfigured.
- Public API and homepage checks return HTTP 200 for the deployed SHA.
- All production containers remain stable with unchanged restart counts after deployment.
