# Gloss

Gloss is a Markdown viewer for macOS. Double-click a `.md` file and read it as a formatted page,
in a native window, with no chance of changing the file.

It is built for reading the Markdown that lives in git repositories: READMEs, runbooks, specs and
the documents AI agents write. It renders the way GitHub does, follows the file as it changes, and
treats every document as untrusted.

Gloss is not related to the "Gloss Markdown" dialect and does not render its directives.

## What it does

- **Opens Markdown read-only.** `.md`, `.markdown`, `.mdown` and `.mkd` files, in windows or tabs,
  with Open Recent. There is no code path that writes a document.
- **Renders like GitHub.** Tables, task lists, strikethrough, autolinks, footnotes, alerts
  (`> [!NOTE]`), heading anchors and syntax-highlighted code, using
  [cmark-gfm](https://github.com/swiftlang/swift-cmark), the parser GitHub uses. YAML front matter
  is shown as a tidy header.
- **Follows the file.** When the file changes on disk the page updates by itself and keeps your
  place. A moved file is followed; a deleted one stays on screen with a notice.
- **Finds its way around.** A heading outline, find in page, zoom, links to other Markdown files
  that open in Gloss, and relative images from anywhere in the same git repository.
- **Fills in forms.** A blank table cell or a run of underscores (`___`) becomes a field, task-list
  boxes can be ticked, and form controls written in HTML work. See [Forms](#forms).
- **Prints and exports.** Paginated printing with a print stylesheet, and export as PDF.
  **File → Show in Finder** (⇧⌘R) opens the document's folder with the file selected.
- **Looks the way you want.** Three built-in themes (Gloss Dark, Gloss Light, Longform), an Auto
  mode that follows the system, and installable theme bundles.
- **Draws diagrams and math.** Mermaid diagrams and KaTeX math, as built-in add-ons that load only
  on pages that use them.
- **Includes a Quick Look preview extension** (experimental; see [Limits](#limits-worth-knowing)).
- **Can be driven by a script or an AI assistant.** See [Scripting](#scripting).

## How it treats a document

A Markdown file from anywhere should be safe to open.

- The page is shown in a web view that can load files only through Gloss's own `gloss:` URL
  scheme. That scheme serves the document's directory tree (the enclosing git repository if there
  is one, otherwise the document's folder), Gloss's own page files, and the bundles in use. It
  refuses any path that leads outside them, including through a symlink.
- A content security policy blocks every script a document contains, inline event handlers, and
  every network load.
- Raw HTML in a document goes through an allowlist sanitizer modelled on GitHub's. `<details>`,
  `<kbd>`, `<sub>`, plain markup and form controls work; scripts, styles, `<form>`, buttons and
  frames are removed. A document cannot ask for a password or a file, and nothing typed into a
  field can be sent anywhere.
- **Nothing is fetched from the network.** A document that refers to remote images shows a bar
  offering to load them, for that document only, until the window closes.
- Gloss has no accounts, telemetry or update checks.

## Install

Download the disk image from the Releases page, open it, and drag Gloss to Applications. It needs
an Apple-silicon Mac on the current macOS release (27 or later).

The first time you open a document, Gloss offers to become the default app for Markdown files.
You can change that later in Settings.

## Forms

Gloss is a viewer, but a document can still ask its reader to fill something in, and the answers
can be exported as JSON to paste or share. Nothing is written to the file.

Fields come from three places, and the first two need no special syntax, so the document reads
the same on GitHub:

- **Blanks.** An empty table cell, or a cell holding only `___`, becomes a text box that looks
  empty until you use it. A run of three or more underscores in a paragraph or list item becomes
  a line to write on. Underscores inside code are left alone.
- **Task lists.** `- [ ] item` boxes can be ticked.
- **HTML form controls**, written in the document:

  ```html
  <label><input type="radio" name="size" value="s"> Small</label>
  <label><input type="radio" name="size" value="l"> Large</label>
  <select name="colour"><option>red</option><option>blue</option></select>
  <input type="date" name="due">
  <textarea name="notes" placeholder="Anything else?"></textarea>
  ```

  `input` may be `text`, `search`, `number`, `range`, `date`, `time`, `datetime-local`, `month`,
  `week`, `email`, `url`, `tel`, `color`, `checkbox` or `radio`. `textarea`, `select`, `option`,
  `optgroup`, `label`, `fieldset` and `legend` work too. `password`, `file`, `hidden`, buttons
  and `<form>` are removed.

The **Export Form** toolbar button (shown when a document has fields) copies, saves or shares the
answers; File → Export Form as JSON… and Copy Form as JSON (⌥⇧⌘C) do the same. The export
looks like this:

```json
{
  "document": "review.md",
  "exported": "2026-11-13T21:04:05Z",
  "values": {
    "Review / Ship it? / Answer": "yes",
    "size": "s"
  },
  "fields": [
    { "type": "textarea", "section": "Review", "row": "Ship it?", "column": "Answer", "line": 5, "value": "yes" },
    { "type": "radio", "name": "size", "section": "Choices", "line": 16, "options": ["s", "l"], "value": "s" }
  ]
}
```

[skills/gloss/AUTHORING.md](skills/gloss/AUTHORING.md) has the full reference, written for an AI
that generates such documents: which field to use for what, how each one looks on GitHub and in
other viewers, and how to read the export.

`values` is the short form: each answer under the field's `name`, or, for a field without one,
under where it is (heading, table row and column, or the words before it). `fields` has every
field in document order with its place and the line it is on. A checkbox is `true` or `false`;
checkboxes sharing a name, and a multiple select, give a list.

Answers stay in the window. They survive the file changing on disk, a theme change and printing,
but Gloss keeps no copy, so closing a window, or quitting, with answers not yet exported asks
whether to save or copy them first.

## Themes and add-ons

Settings → General chooses the appearance (Auto, Light or Dark) and which theme each one uses.
Text width fills the window by default; switch it to the theme's measure there, or with View →
Fit Text to Window, for a narrower reading column.
Settings → Bundles lists what is installed, switches add-ons on and off, and installs or removes
bundles.

A bundle is a folder ending in `.glossbundle`. Double-click one to install it. Built-in bundles
cannot be changed or replaced. A theme can be as small as one CSS file that sets a few colours;
[docs/bundles.md](docs/bundles.md) is the full guide for authors.

Bundle scripts run on the pages you open and can read their text. They cannot use the network or
touch files. Gloss tells you when a bundle contains scripts before it installs it.

The Dock icon can be switched between two designs in Settings. macOS only lets an app change its
Dock icon while it is running, so Finder and Launchpad always show the standard one.

## Scripting

Gloss has an AppleScript dictionary, so a script or an AI assistant can drive it and check what it
shows. Documents are read-only to scripts: there are no verbs that save, create or delete. The only
things a script can change are your settings (appearance, themes, text width, zoom).

```applescript
tell application "Gloss"
  open POSIX file "/path/to/README.md"
  repeat until not (loading of document "README.md")
    delay 0.1
  end repeat
  get {outline, page text} of document "README.md"
end tell
```

### For your AI assistant

`skills/gloss` is a ready-made skill: a `SKILL.md` that tells an assistant when and how to use
Gloss, and a small `gloss` command that wraps the AppleScript. To give it to an assistant such as
Claude Code, copy the folder into its skills directory:

```sh
cp -R skills/gloss ~/.claude/skills/gloss
```

`skills/gloss/AUTHORING.md` is the part for writing: what Gloss renders, how to write a form,
how it degrades in other viewers, and how to read the exported answers.

The same guide is built into the app, so an assistant with no skill installed can ask for it:

```sh
osascript -e 'tell application "Gloss" to get agent guide'
```

There is no standard way for a Mac app to hand an assistant a skill. The standard part is the
scripting dictionary, which any app with AppleScript support publishes and which `sdef
/Applications/Gloss.app` prints; `agent guide` is Gloss's own addition on top of it.

## Limits worth knowing

- **Quick Look is experimental.** The preview extension is built, signed and registered, but in
  testing macOS still showed its own plain-text preview for Markdown files instead of Gloss's, and
  the cause has not been found. If it does appear for you (it may need enabling under System
  Settings → General → Login Items & Extensions → Quick Look), it is simpler than the app: macOS
  gives a preview only the one file, so images stored beside the document do not appear, diagrams
  and math are shown as their source, and it always uses the built-in themes.
- **Math needs explicit delimiters.** `$$…$$`, `\[…\]`, `\(…\)`, a `math` code block, or GitHub's
  `` $`…`$ `` inline form. A lone `$…$` is left alone, because in technical documents a dollar
  sign is usually a price or a shell variable.
- **Emoji shortcodes** such as `:tada:` are shown as written.

## Reporting a problem

**Help → Report an Issue…** opens a new GitHub issue in your browser with the Gloss and macOS
versions filled in. Nothing about the document you have open is included, and nothing is sent
until you submit the issue yourself.

## Build and test

You need Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
[create-dmg](https://github.com/create-dmg/create-dmg) for release images. The Xcode project is
generated from `project.yml` and is not checked in.

```sh
make build      # generate the project and build, unsigned
make core-test  # the render core's tests (also what CI runs, on Linux)
make test       # the app's tests, in a real web view
make check      # both; run this before opening a pull request
```

CI runs only the render core's tests. The app needs the newest macOS SDK, which hosted runners may
not carry, so `make check` on a Mac is the gate for app changes.

## Layout

| Path | What it is |
|---|---|
| `Packages/GlossCore` | The render core: Markdown in, HTML and document metadata out. No UI dependency. |
| `App` | The macOS app: documents, the page, the `gloss:` scheme handler, settings. |
| `App/Bundles` | The built-in themes and add-ons. |
| `QuickLook` | The Quick Look preview extension. |
| `AppTests` | Tests that load pages in a real web view. |
| `skills/gloss` | A skill that lets an AI assistant drive Gloss over AppleScript. |
| `scripts/release.sh` | Builds, signs, notarizes and staples a release disk image. |
| `docs` | The bundle guide and design notes. |

## Third-party software

Gloss includes [cmark-gfm](https://github.com/swiftlang/swift-cmark) (BSD 2-Clause),
[highlight.js](https://highlightjs.org) (BSD 3-Clause), [Mermaid](https://mermaid.js.org) (MIT)
and [KaTeX](https://katex.org) (MIT). Their licences are in the repository beside the files.

## Licence

MIT. See [LICENSE](LICENSE).
