# Mixli v2 asset QA

The v2 kit was rebuilt from the approved final reference after rejecting the first synthetic reconstruction.

## Automated validation
- Every SVG XML-parses and rasterizes successfully with CairoSVG.
- Every PNG opens successfully and has recorded dimensions/alpha range.
- iOS/PWA app-icon source exports are full-square and fully opaque; Android adaptive foreground retains transparency.
- Primary and secondary semantic text colors pass WCAG AA normal-text contrast on their intended light/dark canvases.
- Reference-vs-vector silhouette measurements are recorded in the packaged QA data.

## Visual validation
- Logo/lockup variants reviewed on intended light and dark backgrounds.
- App icon reviewed from 1024 px through 32 px; one-color favicon reviewed at 16/32/48/64 px.
- All 28 UI symbols reviewed at 72 px and at their native 24 px grid.
- Share and External Link are separate glyphs.
- Six empty-state families reviewed in both themes.
- Marketing templates reviewed together for spacing, hierarchy, clipping and contrast.

## Production constraints
- Official wordmark is outlined vector geometry; never substitute typed text.
- Marketing templates keep live Inter text for editability; logo artwork itself has no font dependency.
- Identity gradient colors are decorative/brand accents and are not approved for normal body copy.
