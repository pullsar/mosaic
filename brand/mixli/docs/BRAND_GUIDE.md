# Mixli Brand System v1.0

**Play. Learn. Become.**

This package is the production source of truth for Mixli's initial identity. The logo is original vector geometry: four open paths converge without forming a mathematical ×, representing playful exploration, learning, transformation and becoming.

## 1. Brand idea

**Four paths. One journey.** The identity should feel curious, alive and optimistic without becoming childish or visually noisy. The four-path mark is expressive; the product UI around it is deliberately restrained.

## 2. Typography

### Product UI — Inter Variable
Use Inter Variable for all functional UI. It was designed for computer screens, with a tall x-height for mixed/lowercase readability and OpenType features useful in interfaces. Use Regular 400, Medium 500 and Semibold 600 most of the time. Avoid Light/Thin for functional text.

### Display — Inter Display / Inter Variable at display optical size
Use Inter Display for large marketing and editorial headings. This keeps one type family in the stack, minimizes font payload and avoids a decorative display font competing with Play content. The custom Mixli wordmark provides the distinctive brand voice.

**Do not bundle or redistribute font files with brand assets.** Reference the official Inter project or your licensed application bundle.

### Product roles
- Display: 56/60, 650, -1.8 tracking
- Headline: 32/38, 600
- Play prompt: 22/28, 600
- Choice: 17/22, 500
- Reveal title: 24/30, 650
- Reveal detail: 16/23, 400
- Control: 14/18, 550
- Metadata: 12/16, 500

## 3. Logo

Primary: `logo/svg/wordmark-color.svg`.

The four-path icon may be used alone only when context already identifies Mixli (app icon, favicon, avatar, in-product branded moment). Use the wordmark for first-contact marketing and institutional surfaces.

Clear space: at least one **i-dot diameter** around the wordmark and one **path stroke width** around the icon. Minimum recommended icon: 20 px digital. Minimum full wordmark: 96 px digital.

Do not rotate, outline, add shadows, recolor individual paths, or place the gradient logo on a visually busy image without a quieting surface.

## 4. Color system

Core neutrals: Ink `#0B1230`, Paper `#F8FAFF`, Dark `#080D20`.

Identity paths: Play `#FF6B61`, Learn `#8A5CFF`, Transform `#23C7D9`, Become `#1778F2`. These accents are **not** body-text colors on light surfaces; use semantic text colors for accessibility.

Light text uses Ink / Muted `#566078`. Dark text uses Paper / Muted Dark `#B8C0D8`. The normal text combinations are chosen to meet or exceed WCAG AA contrast; decorative gradient elements do not communicate state by color alone.

## 5. Gradient rules

The Journey gradient order is always **coral → violet → cyan → blue**. It expresses Play → Learn → Transform → Become. Reverse direction only when motion direction requires it; never randomly reorder the stops.

Use gradients for:
- logo/icon identity;
- meaningful progress or transition moments;
- sparse ambient brand ribbons;
- empty-state illustration accents;
- launch/marketing surfaces.

Do not use gradients for body text, ordinary buttons, every card, or persistent navigation.

## 6. Light / dark

Light: Paper background, white raised surfaces, Ink text.
Dark: Dark `#080D20` background, raised `#111938`, Paper text.

The colorful logo works on both. Prefer white monochrome logo only where the full-color mark would fight the content. Product controls remain `currentColor` monochrome and inherit the theme.

## 7. Iconography

The app icon system is a 24×24 grid, 1.8 px optical stroke, round caps and joins. It is intentionally familiar and low-noise. The SVGs use `currentColor`; recolor through the UI theme rather than editing files.

Do not replace familiar symbols simply to look branded. Brand differentiation belongs in the four-path mark, motion, content quality and composition.

## 8. Empty states

Empty-state illustrations are text-free SVGs. Pair each with one literal title and at most one short action. No motivational paragraphs. Available states: Saved, Offline, No results, First creation, Permission required.

## 9. Marketing

Marketing templates are vector-first SVGs with matching PNG exports. Replace copy in SVG source rather than raster-editing. Dark is the hero/launch treatment; light is used for documentation, press and email. The flowing Journey ribbon should remain secondary to the message.

## 10. Product restraint

On the Play surface: no persistent wordmark, no logo watermark over creator media, no gradient navigation tower, and no brand ornament unless it improves comprehension or feedback. Mixli should be recognized by craft before chrome.

## 11. Package map

- `logo/` — transparent wordmark, icon and lockups
- `app-icons/` — opaque store/home-screen tiles plus SVG source
- `icons/` — immediate mobile/web product icon set
- `empty-states/` — text-free light/dark illustrations
- `marketing/` — share cards, story/post templates, hero ribbon
- `tokens/` — JSON design tokens, CSS and Flutter constants
- `source/` — source notes / generation metadata

## 12. Accessibility

Normal text must target at least 4.5:1 contrast. Large text may use 3:1 where WCAG permits. Do not encode success/error/selection solely by Play/Learn/Transform/Become color. Respect scalable text and reduced motion.
