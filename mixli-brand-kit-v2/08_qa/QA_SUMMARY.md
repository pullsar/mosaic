# Mixli v2 asset QA summary

This package was rebuilt from the approved final reference rather than from the rejected v1 geometry.

## Automated validation
- Every SVG XML-parses and rasterizes successfully with CairoSVG.
- Every PNG opens successfully and has recorded dimensions/alpha range.
- iOS/PWA app icons are full-square and fully opaque; Android adaptive foreground preserves alpha.
- WCAG AA normal-text contrast checks pass for primary/secondary light and dark semantic text colors.
- Reference-vs-vector silhouette checks are recorded in `reference-similarity.json`.

## Visual review performed
- Logo variants reviewed on their intended light/dark backgrounds.
- App icon reviewed at 1024 and down to 32 px; favicon checked at 16/32/48/64 px.
- All 28 UI symbols reviewed at 72 px and native 24 px (nearest-neighbor QA sheet).
- Share and External Link are intentionally distinct symbols.
- All six empty-state families reviewed in both themes.
- All marketing templates reviewed as a contact sheet.

## Known intentional constraints
- White/dark logo PNGs are transparent assets; judge them only on their intended contrasting background.
- Marketing SVG templates retain live Inter text for editability; production logo artwork itself is fully outlined.
- Gradient identity colors are not approved for normal body text.

## Defects caught and corrected during audit
- Removed baked rounded corners from full-square iOS/PWA app-icon sources; platform masks now own corner shape.
- Separated Share from External Link after detecting duplicate semantics in the first pass.
- Reworked selected Create icon to remove a literal-white foreground dependency; it is now fully theme-safe through `currentColor`.
- Removed a redundant stacked logo variant that duplicated the mark.
