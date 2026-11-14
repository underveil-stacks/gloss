# Built-in themes: design notes

How the base stylesheet and the three built-in themes were designed, and what a theme author
should know before writing a fourth. The contract they are written against is
[`docs/bundles.md`](../bundles.md); nothing here changes it.

To see everything described below, open [`fixture.html`](fixture.html) from disk. It follows the
contract's page structure, exercises every element the base stylesheet styles, and has a switcher
for theme and appearance.

## What is being read

Agent-written and git-tracked technical documents: wide tables, nested lists, a fenced block
every few paragraphs, inline code in most sentences. The window is anything from a 500 px tile
beside an editor to a full monitor. So the design goal is a page that stays calm at that density:
one column, one scale, colour kept for the things that are code, links or warnings.

## Type scale

Fixed steps, not fluid ones. A heading that shrinks as the window narrows reads as a different
document; at 480 px the column narrows and the type does not.

| Element | Size | Weight | Tracking | Line height |
|---|---|---|---|---|
| h1 | 2rem | 700 | -0.022em | 1.15 |
| h2 | 1.5rem | 650 | -0.017em | 1.25 |
| h3 | 1.25rem | 650 | -0.011em | 1.25 |
| h4 | 1.0625rem | 650 | 0 | 1.25 |
| h5 | 1rem | 650 | 0 | 1.25 |
| h6 | 0.875rem, muted | 650 | 0 | 1.25 |
| Body | `--gloss-font-size` (16px) | 400 | 0 | `--gloss-line-height` (1.6) |
| Inline code | 0.875em | | | |
| Code block | 0.85rem | | | 1.55 |
| Table | 0.9375rem | | | 1.45 |
| Footnotes, front matter | 0.875 | | | |

- The ratio is about 1.2 from h4 up to h2, then 1.33 to h1. Technical documents use four or five
  heading levels on one screen; a steeper scale turns that into noise. h4 to h6 are told apart
  by size only slightly, and h6 by colour, because by that depth the reader is navigating by
  position, not by size.
- The base size is set on `html`, so `rem` follows `--gloss-font-size`. Block margins and the
  measure are in `rem`: a theme that raises the font size gets a proportionally wider column and
  the same rhythm without touching anything else.
- Block spacing is `1.1rem` for every block, in `rem` so a code block (smaller type) keeps the
  same gap as a paragraph. Headings have about three times more space above than below.
- **Measure.** `--gloss-measure` is the width of the text itself; the gutter is added outside it.
  Gloss Dark and Light use `40rem`: measured in WebKit that is about 92 characters of body text
  per line and 72 columns of code. That is longer than the 65 to 75 a book would use. It is a
  deliberate trade for documents that are half code: a narrower column makes every other code
  block scroll. Longform uses `32rem` at 18px, measured at about 74 characters.
  The measure is the reader's choice, not only the theme's: by default the text fills the window
  (Settings → Text width, or View → Fit Text to Window), and the theme's measure applies when the
  reader turns that off.

## The three themes

- **Gloss Dark** (default) and **Gloss Light** are one family: the same hue does the same job in
  both. Blue is links and function names, pink is the accent (quote bars, list markers,
  checkboxes) and numbers, purple is keywords, green is strings, cyan is types. Both are token
  assignments only, with no rules of their own.
- **Longform** is a different voice for prose: the system serif (`ui-serif`, which is New York in
  WebKit) at 18px, 1.7 leading, a 32rem measure, on a paper ground in light and charcoal in dark.
  It adds a few rules a token cannot express: lighter heading weight, no rule under h2, italic
  quotations, a slightly smaller mono, and tables set in the system sans.

### No warm colours in Gloss Dark

Gloss Dark uses no red, orange, yellow, amber or brown anywhere, syntax and alerts included. The
five alert kinds are spread as far apart as the cool half of the wheel allows, about 50° of hue
each: tip green (160°), **warning cyan (205°)**, note blue (252°), important purple (305°),
**caution pink (352°)**. Caution takes pink because it is the cool hue nearest red; warning takes
cyan by elimination.

Five hues inside 200° are not reliably distinct for every reader, so colour is never the only
signal. Each alert title is the kind's name in words, and carries a shape drawn in CSS: a circle
for note, a diamond for tip, a square for important, a triangle for warning, a cross for caution.
Gloss Light follows the same assignment. Longform is not bound by the rule and uses an amber
warning and a red caution.

## Palettes and contrast

Ratios are WCAG 2 contrast ratios, computed from the hex values in the shipped CSS (the script
that produced these tables also asserts that each value matches the theme file). The floor aimed
for is 4.5:1 for all text, including muted text, comments and every syntax colour, against the
surface it actually sits on. Borders are decorative and are not held to a ratio.

### Gloss Dark

| Token | Value | Measured against | Ratio |
|---|---|---|---|
| `--gloss-bg` | `#101422` | | |
| `--gloss-surface` | `#181c2d` | | |
| `--gloss-surface-raised` | `#23283c` | | |
| `--gloss-border` | `#383e58` | bg (decorative) | 1.74 |
| `--gloss-text` | `#d4d9e8` | bg | 13.00 |
| `--gloss-text-muted` | `#a0a8c3` | bg | 7.76 |
| `--gloss-heading` | `#f0f3fc` | bg | 16.53 |
| `--gloss-link` | `#80bcff` | bg | 9.22 |
| `--gloss-link-hover` | `#a1dcff` | bg | 12.40 |
| `--gloss-accent` | `#fa8ac2` | bg | 8.28 |
| `--gloss-text` | `#d4d9e8` | surface-raised (inline code) | 10.34 |
| `--gloss-text-muted` | `#a0a8c3` | surface (front-matter keys) | 7.15 |
| `--gloss-selection` | `#3e275e` | weakest text on it: text-muted 5.36, code-comment 5.00, link 6.37 | 5.00 |
| `--gloss-code-text` | `#d4d9e8` | surface | 11.98 |
| `--gloss-code-comment` | `#99a2c0` | surface | 6.67 |
| `--gloss-code-keyword` | `#c99cfc` | surface | 7.76 |
| `--gloss-code-string` | `#72e5b0` | surface | 10.90 |
| `--gloss-code-number` | `#fc9ac9` | surface | 8.53 |
| `--gloss-code-function` | `#80c0ff` | surface | 8.77 |
| `--gloss-code-type` | `#79dde8` | surface | 10.72 |
| `--gloss-code-variable` | `#c8c4f6` | surface | 10.20 |
| `--gloss-code-meta` | `#7dbbd7` | surface | 8.02 |
| `--gloss-code-addition` | `#76e699` | surface | 10.90 |
| `--gloss-code-deletion` | `#ff7fbc` | surface | 7.25 |
| `--gloss-alert-note` | `#80bcff` | its own panel `#1b2538` (title) | 7.71 |
| `--gloss-alert-tip` | `#65e0a5` | its own panel `#18282f` (title) | 9.22 |
| `--gloss-alert-important` | `#c99cfc` | its own panel `#222238` (title) | 7.12 |
| `--gloss-alert-warning` | `#6cdeeb` | its own panel `#192836` (title) | 9.50 |
| `--gloss-alert-caution` | `#ff7fbc` | its own panel `#281f31` (title) | 6.77 |

Body text on the alert panels is at least 10.65:1. Diff lines on their own wash: addition 8.34, deletion 5.93. Lowest text ratio in the theme: 6.17.

### Gloss Light

| Token | Value | Measured against | Ratio |
|---|---|---|---|
| `--gloss-bg` | `#f9fafe` | | |
| `--gloss-surface` | `#edf0f8` | | |
| `--gloss-surface-raised` | `#e2e6f3` | | |
| `--gloss-border` | `#ccd0e2` | bg (decorative) | 1.47 |
| `--gloss-text` | `#252a3d` | bg | 13.63 |
| `--gloss-text-muted` | `#555d75` | bg | 6.27 |
| `--gloss-heading` | `#101428` | bg | 17.47 |
| `--gloss-link` | `#154fc3` | bg | 6.85 |
| `--gloss-link-hover` | `#0f2e94` | bg | 10.95 |
| `--gloss-accent` | `#bd1478` | bg | 5.70 |
| `--gloss-text` | `#252a3d` | surface-raised (inline code) | 11.40 |
| `--gloss-text-muted` | `#555d75` | surface (front-matter keys) | 5.74 |
| `--gloss-selection` | `#e3d7fb` | weakest text on it: text-muted 4.79, code-comment 4.80, link 5.23 | 4.79 |
| `--gloss-code-text` | `#252a3d` | surface | 12.47 |
| `--gloss-code-comment` | `#565d72` | surface | 5.75 |
| `--gloss-code-keyword` | `#7522b3` | surface | 6.99 |
| `--gloss-code-string` | `#00663a` | surface | 6.22 |
| `--gloss-code-number` | `#b2006f` | surface | 5.90 |
| `--gloss-code-function` | `#004cbb` | surface | 6.70 |
| `--gloss-code-type` | `#006174` | surface | 6.22 |
| `--gloss-code-variable` | `#48408b` | surface | 7.73 |
| `--gloss-code-meta` | `#2f617d` | surface | 5.89 |
| `--gloss-code-addition` | `#006328` | surface | 6.54 |
| `--gloss-code-deletion` | `#aa0061` | surface | 6.39 |
| `--gloss-alert-note` | `#154fc3` | its own panel `#e2e9f8` (title) | 5.87 |
| `--gloss-alert-tip` | `#00663a` | its own panel `#e0ebea` (title) | 5.82 |
| `--gloss-alert-important` | `#7522b3` | its own panel `#ece4f6` (title) | 6.45 |
| `--gloss-alert-warning` | `#006174` | its own panel `#e0ebf0` (title) | 5.84 |
| `--gloss-alert-caution` | `#b70069` | its own panel `#f2e1ef` (title) | 5.22 |

Body text on the alert panels is at least 11.37:1. Diff lines on their own wash: addition 5.45, deletion 5.13. Lowest text ratio in the theme: 5.25.

### Longform, light

| Token | Value | Measured against | Ratio |
|---|---|---|---|
| `--gloss-bg` | `#f9f6f0` | | |
| `--gloss-surface` | `#f0ece4` | | |
| `--gloss-surface-raised` | `#e7e2d8` | | |
| `--gloss-border` | `#d4cdc1` | bg (decorative) | 1.46 |
| `--gloss-text` | `#2b2521` | bg | 14.01 |
| `--gloss-text-muted` | `#615952` | bg | 6.36 |
| `--gloss-heading` | `#1a1511` | bg | 16.79 |
| `--gloss-link` | `#005a5f` | bg | 7.41 |
| `--gloss-link-hover` | `#003d45` | bg | 11.10 |
| `--gloss-accent` | `#892f59` | bg | 7.45 |
| `--gloss-text` | `#2b2521` | surface-raised (inline code) | 11.71 |
| `--gloss-text-muted` | `#615952` | surface (front-matter keys) | 5.83 |
| `--gloss-selection` | `#c0e7e8` | weakest text on it: text-muted 5.18, code-comment 4.96, link 6.03 | 4.96 |
| `--gloss-code-text` | `#302a25` | surface | 12.01 |
| `--gloss-code-comment` | `#635c55` | surface | 5.58 |
| `--gloss-code-keyword` | `#862c56` | surface | 7.11 |
| `--gloss-code-string` | `#255d34` | surface | 6.62 |
| `--gloss-code-number` | `#62488c` | surface | 6.31 |
| `--gloss-code-function` | `#0b517f` | surface | 7.14 |
| `--gloss-code-type` | `#005a5f` | surface | 6.78 |
| `--gloss-code-variable` | `#3e4058` | surface | 8.57 |
| `--gloss-code-meta` | `#4f606d` | surface | 5.52 |
| `--gloss-code-addition` | `#1c5f31` | surface | 6.53 |
| `--gloss-code-deletion` | `#9d2a3f` | surface | 6.28 |
| `--gloss-alert-note` | `#0b517f` | its own panel `#e1e6e5` (title) | 6.67 |
| `--gloss-alert-tip` | `#255d34` | its own panel `#e4e7dd` (title) | 6.23 |
| `--gloss-alert-important` | `#62488c` | its own panel `#eae5e6` (title) | 5.96 |
| `--gloss-alert-warning` | `#7e4f04` | its own panel `#ede5d8` (title) | 5.59 |
| `--gloss-alert-caution` | `#9e2c2c` | its own panel `#f0e2dc` (title) | 5.83 |

Body text on the alert panels is at least 11.96:1. Diff lines on their own wash: addition 5.47, deletion 5.22. Lowest text ratio in the theme: 5.32.

### Longform, dark

| Token | Value | Measured against | Ratio |
|---|---|---|---|
| `--gloss-bg` | `#181512` | | |
| `--gloss-surface` | `#211d1a` | | |
| `--gloss-surface-raised` | `#2c2824` | | |
| `--gloss-border` | `#413c36` | bg (decorative) | 1.67 |
| `--gloss-text` | `#d6d0c5` | bg | 11.85 |
| `--gloss-text-muted` | `#aaa49a` | bg | 7.35 |
| `--gloss-heading` | `#efebe1` | bg | 15.28 |
| `--gloss-link` | `#82cdcd` | bg | 10.01 |
| `--gloss-link-hover` | `#ade8e7` | bg | 13.40 |
| `--gloss-accent` | `#e496b4` | bg | 8.07 |
| `--gloss-text` | `#d6d0c5` | surface-raised (inline code) | 9.53 |
| `--gloss-text-muted` | `#aaa49a` | surface (front-matter keys) | 6.76 |
| `--gloss-selection` | `#15383a` | weakest text on it: text-muted 5.12, code-comment 4.76, link 6.97 | 4.76 |
| `--gloss-code-text` | `#d6d0c5` | surface | 10.90 |
| `--gloss-code-comment` | `#a49e94` | surface | 6.29 |
| `--gloss-code-keyword` | `#eb9dbb` | surface | 8.02 |
| `--gloss-code-string` | `#94cf9f` | surface | 9.31 |
| `--gloss-code-number` | `#c0abe9` | surface | 8.16 |
| `--gloss-code-function` | `#8fc1eb` | surface | 8.76 |
| `--gloss-code-type` | `#82cdcd` | surface | 9.21 |
| `--gloss-code-variable` | `#c5c9e2` | surface | 10.22 |
| `--gloss-code-meta` | `#94a8b6` | surface | 6.80 |
| `--gloss-code-addition` | `#89d298` | surface | 9.35 |
| `--gloss-code-deletion` | `#f18790` | surface | 6.86 |
| `--gloss-alert-note` | `#8fc1eb` | its own panel `#242628` (title) | 7.95 |
| `--gloss-alert-tip` | `#94cf9f` | its own panel `#242820` (title) | 8.35 |
| `--gloss-alert-important` | `#c0abe9` | its own panel `#292428` (title) | 7.44 |
| `--gloss-alert-warning` | `#e6bd77` | its own panel `#2d261c` (title) | 8.47 |
| `--gloss-alert-caution` | `#f28881` | its own panel `#2e201d` (title) | 6.43 |

Body text on the alert panels is at least 9.74:1. Diff lines on their own wash: addition 7.26, deletion 5.58. Lowest text ratio in the theme: 5.91.

The no-theme defaults in `base.css` are derived with `color-mix()` from whatever `--gloss-bg`,
`--gloss-text` and `--gloss-link` resolve to, so their ratios depend on the theme that supplies
those three. They were looked at in both appearances but not measured token by token.

## Decisions a theme author should know

- **Token defaults have zero specificity.** They are declared inside `:where()`, so the minimal
  theme in the contract, one `:root { … }` rule, wins in both appearances. Surfaces, borders,
  muted text, hover and selection colours are derived from `--gloss-bg`, `--gloss-text`,
  `--gloss-link` and `--gloss-accent`; set those four and the rest follows.
- **Selection sets a background and no text colour**, so syntax and link colours survive being
  selected. Pick `--gloss-selection` so your weakest text (usually `--gloss-code-comment` or
  `--gloss-text-muted`) still clears 4.5:1 on it. A selection colour that looks right on body
  text is often too bright for comments.
- **Alert panels are derived, not tokens.** The fill is the alert colour at 10% over
  `--gloss-bg`, the border at 34%, and the title is the alert colour itself. An alert token must
  therefore read as text on a tint of itself.
- **Inline code sits on `--gloss-surface-raised`**, code blocks on `--gloss-surface`. Check
  `--gloss-code-*` against the surface, not the page background.
- **Links are underlined at rest.** Hover and keyboard focus change the colour, thicken the
  underline from 1px to 2px and make it fully opaque, so the state shows without relying on hue.
  The colour change is a 120 ms transition, removed under `prefers-reduced-motion`.
- **Tables are their own scroll container.** A table is never wider than the column. Body cells
  ask for their full width up to 26em, so short cells stay on one line and prose cells wrap at
  the cap; a table that outgrows the column scrolls sideways inside it. This relies on WebKit
  honouring `width: max-content` with `max-width` on a table cell, which it does (measured), and
  which other engines may not.
- **Scroll shading.** Code blocks and tables show a soft shade on an edge only while content is
  scrolled out of view on that side. It is drawn with layered backgrounds, no script. In a table
  the header row's fill covers it, so the shade starts below the header.
- **Task-list checkboxes are drawn in CSS** from `--gloss-accent` and `--gloss-bg`, because the
  page's content security policy allows no `data:` images and a disabled native checkbox is grey
  whatever the theme. The tick is two gradient strokes.
- **highlight.js classes beyond the token table** are mapped to the nearest token so they are not
  left as plain text: `doctag` and `operator` to keyword; `selector-class` and `selector-id` to
  function; `template-variable`, `selector-attr`, `selector-pseudo` and `params` to variable;
  `bullet` to number; `link` to string. `punctuation` and `subst` stay the default code colour.
- **`color-scheme` follows `data-appearance`**, never the system setting, so native scrollbars
  match the page. Dark pages also use antialiased font smoothing.
- **Print resets every token with `!important`.** It is the only place the base uses it: print
  must beat a theme whose selectors and load order it cannot know. A theme that wants its own
  print look supplies `printStyles`.
- **Fonts are system fonts only.** `ui-serif` and `ui-monospace` resolve in WebKit; the named
  faces after them in each stack are fallbacks for other engines and are what you will see if
  you open the fixture in Firefox.
- **Not used on purpose:** old-style figures in Longform. They make `app-01` read as
  `app-o1`, which is the wrong trade in a viewer for technical documents.
