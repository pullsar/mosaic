# Production asset catalog

The audited handoff is organized as follows.

- `01_logo/` — outlined wordmark, four-loop icon, light/dark and monochrome variants, `Play. Learn. Become.` lockups.
- `02_app_icons/` — full-square opaque app icon sources/exports plus transparent Android adaptive foreground and micro favicon.
- `03_ui_icons/` — 28 themeable 24×24 SVG symbols, PNG reference exports at 24/48/72, and combined web sprite.
- `04_empty_states/` — Saved, Search, Offline, Create, Notifications and Following illustrations in both themes; artwork contains no text.
- `05_marketing/` — editable SVG hero, OG/share, square, story and Journey-ribbon templates in light/dark.
- `06_tokens/` — design-token JSON, CSS custom properties and Flutter constants.
- `07_docs/` — brand, typography, iconography and implementation guidance.
- `08_qa/` — machine validation, contrast audit, app-icon alpha audit, reference similarity, manifest/checksums.
- `09_previews/` — contact sheets used for human QA; not production sources.

Prefer SVG for runtime logos/icons where supported. PNG exports are handoff/reference assets and fixed-size platform requirements.
