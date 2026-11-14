# Bundles: themes and add-ons

A bundle is a folder whose name ends in `.glossbundle`. Finder shows it as a single file.
Double-click one to install it; remove it in Settings. Built-in bundles live inside the app and
cannot be changed, replaced or shadowed.

There are two kinds:

- A **theme** changes how a page looks. One theme is active for the light appearance and one for
  the dark appearance; "Auto" follows the system.
- An **add-on** adds a capability, such as diagrams or math. Any number can be on at once, and they
  work with every theme.

This document is contract version **1**.

## Layout

```
Aurora.glossbundle/
  manifest.json
  theme.css
  fonts/…
```

## manifest.json

```json
{
  "contract": 1,
  "id": "com.example.aurora",
  "name": "Aurora",
  "author": "Someone",
  "version": "1.0.0",
  "kind": "theme",
  "appearances": ["dark"],
  "styles": ["theme.css"],
  "scripts": []
}
```

| Key | Required | Meaning |
|---|---|---|
| `contract` | yes | The contract version the bundle was written for. A bundle for a newer contract is refused. |
| `id` | yes | Reverse-DNS identifier: letters, digits, `.` and `-`. Unique among installed bundles. |
| `name` | yes | Shown in Settings. |
| `author` | no | Shown in Settings. |
| `version` | yes | Shown in Settings. |
| `kind` | yes | `"theme"` or `"add-on"`. |
| `appearances` | themes | `["light"]`, `["dark"]` or `["light", "dark"]`. |
| `styles` | no | CSS files, loaded in order. |
| `scripts` | no | JavaScript files, loaded in order, each as a classic script at the end of the body. |
| `printStyles` | no | CSS files loaded for print only. Without it, Gloss's own print stylesheet is used. |
| `inlineStyles` | no | `true` if the bundle's scripts write `style` attributes or `<style>` elements into the page, as diagram and math libraries do. Pages that use the bundle are then served with a policy that allows inline styles. |
| `when` | no | Add-ons only. Loads the add-on just for documents that need it: `{"languages": ["mermaid"]}` for documents with a fenced code block in one of those languages, `{"text": ["$$"]}` for documents whose source contains one of those strings, or both (either is enough). Without it, the add-on loads on every page. |

Paths are relative to the bundle and must stay inside it.

## What a bundle may do

- Its styles and scripts run on every page.
- It may load its own files (fonts, images, more CSS) by relative URL.
- It has **no network access**. Fonts and libraries must be inside the bundle.
- It has no access to the disk and no bridge to the app.
- Installing a bundle with scripts means trusting it with the text of the documents you open.
  It still cannot send that text anywhere.

## The page

Every page has this structure. It is stable within a contract version.

```html
<html data-appearance="dark" data-theme="com.example.aurora">
  <head>…</head>
  <body>
    <header class="gloss-frontmatter">            <!-- only when the file has front matter -->
      <dl>
        <dt>title</dt><dd>Release notes</dd>
        <dt>tags</dt><dd>one, two</dd>
      </dl>
    </header>
    <article class="markdown-body">
      <h1 id="release-notes">Release notes</h1>
      <p>…</p>
      <pre><code class="language-swift hljs">…<span class="hljs-keyword">let</span>…</code></pre>
      <div class="markdown-alert markdown-alert-note">
        <p class="markdown-alert-title">Note</p>
        <p>…</p>
      </div>
      <ul class="contains-task-list">
        <li class="task-list-item"><input type="checkbox" class="gloss-task" checked> done</li>
      </ul>
      <table>…<td><textarea class="gloss-blank" rows="1"></textarea></td>…</table>
      <p>Owner: <input type="text" class="gloss-blank"></p>
      <label><input type="radio" name="user-content-size" value="s"> Small</label>
      <section class="footnotes">…</section>
    </article>
  </body>
</html>
```

- `data-appearance` is `light` or `dark`: the appearance the page is being shown in. A theme that
  supports both keys its colours off it.
- `data-width="window"` is present when the reader asked for the text to fill the window (the
  default). `--gloss-measure` is then `none` whatever the theme sets; the theme's measure applies
  only when the reader chose it.
- Headings have GitHub-style `id`s. Block elements carry `data-sourcepos`; ignore it.
- Alert kinds are `note`, `tip`, `important`, `warning`, `caution`.
- Code is highlighted before the page loads, with [highlight.js](https://highlightjs.org) class
  names (`hljs-keyword`, `hljs-string`, `hljs-comment`, …). A code block with no known language has
  no `hljs` spans.
- Form fields: a blank table cell becomes `textarea.gloss-blank`, a run of underscores becomes
  `input.gloss-blank`, and a task-list checkbox is enabled and given `gloss-task`. Gloss builds
  these before `gloss:render` fires. Controls the document wrote itself (`input`, `textarea`,
  `select`, `label`, `fieldset`, `legend`) arrive with their `name` and `id` prefixed
  `user-content-`. A script may read fields but must not move or replace them: Gloss finds them
  again by position to carry the reader's answers across a re-render.
- A fenced block in a language an add-on handles (for example `mermaid`) arrives as
  `<pre><code class="language-mermaid">` with its source as text.

## Styling with tokens

Gloss loads its own base stylesheet first. It lays out every element above using the custom
properties below, so the smallest useful theme is a single rule that sets them:

```css
:root {
  --gloss-bg: #10131c;
  --gloss-text: #d9def2;
  --gloss-link: #7aa2ff;
}
```

A theme may also override any rule in the base stylesheet, or all of them.

| Token | Used for |
|---|---|
| `--gloss-bg` | Page background |
| `--gloss-surface` | Code blocks, table headers, front matter |
| `--gloss-surface-raised` | Inline code, hover rows |
| `--gloss-border` | Rules, table and block borders |
| `--gloss-text` | Body text |
| `--gloss-text-muted` | Quotes, captions, front-matter keys |
| `--gloss-heading` | Headings |
| `--gloss-link` | Links |
| `--gloss-link-hover` | Links on hover |
| `--gloss-accent` | Quote bars, list markers, selection |
| `--gloss-selection` | Selected-text background |
| `--gloss-font-body` | Body font stack |
| `--gloss-font-heading` | Heading font stack |
| `--gloss-font-mono` | Code font stack |
| `--gloss-font-size` | Base font size |
| `--gloss-line-height` | Body line height |
| `--gloss-measure` | Maximum width of the text column, when the reader has not chosen to fit the window |
| `--gloss-radius` | Corner radius of blocks |
| `--gloss-code-text` | Code, default colour |
| `--gloss-code-comment` | `hljs-comment`, `hljs-quote` |
| `--gloss-code-keyword` | `hljs-keyword`, `hljs-selector-tag`, `hljs-literal` |
| `--gloss-code-string` | `hljs-string`, `hljs-regexp` |
| `--gloss-code-number` | `hljs-number`, `hljs-symbol` |
| `--gloss-code-function` | `hljs-title`, `hljs-function`, `hljs-section` |
| `--gloss-code-type` | `hljs-type`, `hljs-built_in`, `hljs-class` |
| `--gloss-code-variable` | `hljs-variable`, `hljs-attr`, `hljs-attribute`, `hljs-property` |
| `--gloss-code-meta` | `hljs-meta`, `hljs-tag`, `hljs-name` |
| `--gloss-code-addition` | `hljs-addition` |
| `--gloss-code-deletion` | `hljs-deletion` |
| `--gloss-alert-note` | Note alerts |
| `--gloss-alert-tip` | Tip alerts |
| `--gloss-alert-important` | Important alerts |
| `--gloss-alert-warning` | Warning alerts |
| `--gloss-alert-caution` | Caution alerts |

## Scripts

After every render, and again after every re-render when the file changes, the page dispatches an
event on `document`:

```js
document.addEventListener('gloss:render', () => {
  // (re)apply whatever the bundle does
});
```

Scripts are loaded at the end of the body, so the document is already there when they first run;
the event also fires once after they have loaded. Write a script so that running it twice on the
same page is harmless.

A script may load another script from its own bundle, which is how a large library can be fetched
only when a page needs it. The new script must carry the loading script's nonce:

```js
const self = document.currentScript;           // read this at the top level, not in a callback
const script = document.createElement('script');
script.src = new URL('library.min.js', self.src).href;
script.nonce = self.nonce;
document.head.append(script);
```

If a script replaces a block of the page, copy the block's `data-sourcepos` onto the replacement.
Gloss uses it to keep the reader's place when the file changes.

## Developing a bundle

Use **Settings → Bundles → Reveal Bundles Folder**, put your bundle there, and edit it in place:
open windows re-render when a bundle's files change.
