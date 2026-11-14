---
name: gloss
description: Drive and write for the Gloss Markdown viewer (macOS). Use when opening or checking how Markdown renders in Gloss, when writing Markdown the user will read in Gloss, including fill-in forms, or when the user pastes a Gloss form export (JSON with document/values/fields).
---

# gloss — the Gloss Markdown viewer

Gloss is a read-only Markdown viewer for macOS. It is scriptable, so you can open a file in it and
read back exactly what it rendered. Nothing in its scripting interface can change a document:
there is no save, create, delete or edit. The only things a script can change are the reader's
settings: appearance, themes, text width and zoom.

## Writing Markdown for Gloss

[AUTHORING.md](AUTHORING.md) is the reference: what renders, how to ask the reader to fill
something in (blank table cells, `___`, task lists and HTML form controls), how each degrades on
GitHub and other viewers, and how to read the JSON the reader exports. Read it before writing a
document that asks for answers, and when the user pastes an export.

## When to use it

| The user wants | Run |
|---|---|
| "Open this in Gloss" / "show me this Markdown file" | `scripts/gloss open <file>` |
| "What's open in Gloss?" | `scripts/gloss list` |
| "What does this file look like rendered?" / check a Markdown file renders correctly | `scripts/gloss open <file>` then `scripts/gloss text` or `html` |
| The heading structure of a document | `scripts/gloss outline [name]` |
| Which theme a document is shown with, and whether its file still exists | `scripts/gloss info [name]` |
| Close a document / quit the app | `scripts/gloss close [name]` / `scripts/gloss quit` |
| Switch between light and dark, or follow the system | `scripts/gloss set appearance auto\|light\|dark` |
| Change the theme | `scripts/gloss bundles` to list identifiers, then `scripts/gloss set dark-theme <id>` or `set light-theme <id>` |
| Let the text fill the window, or keep the theme's narrower column | `scripts/gloss set text-width window\|theme` |
| Make the text bigger or smaller | `scripts/gloss set zoom 1.25` (0.5 to 3; 1 is actual size) |
| Open Settings for the user | `scripts/gloss settings` |

`[name]` is a document name as printed by `list` (the file name). Leave it out for the front
document.

## How it behaves

- `open` waits until the page has rendered and prints the document's name. Use that name with the
  other commands.
- Rendering is asynchronous. If you write AppleScript yourself, wait until `loading of document`
  is false before reading `page text`, `page html` or `outline`. The script does this for you.
- `text` is what a reader sees. `html` is the page's full HTML, useful for checking structure
  (tables, task lists, footnotes, code blocks).
- The page follows the file: when the file changes on disk, the page updates by itself and keeps
  its place. Give it a moment (about a second) after a write before reading it back. If the file is
  deleted, the last version stays on screen and `info` reports `file missing: true`.
- Remote images are not loaded unless the user asks, and scripts and unsafe HTML in a document are
  removed. That is by design, not a failure.
- Gloss reopens the documents that were open when it last quit, so the front document is not
  always the one you just opened. Refer to documents by name.
- The first time your terminal or agent host scripts Gloss, macOS asks the user to allow it
  (System Settings → Privacy & Security → Automation). A `-1743` error means it was declined.
- Set `GLOSS_APP` to an app path to drive a particular build instead of the installed one.

## Writing AppleScript directly

```applescript
tell application "Gloss"
  open POSIX file "/path/to/README.md"
  repeat until not (loading of document "README.md")
    delay 0.1
  end repeat
  return {outline, page text} of document "README.md"
end tell
```

Documents have `name`, `file`, `loading`, `page text`, `page html`, `outline`, `theme`,
`appearance` and `file missing`, all read-only. The application has `appearance mode`,
`light theme`, `dark theme`, `text width` and `zoom` (settable), `bundle identifiers` and `agent guide`
(read-only), and the command `show settings`. Windows have the usual `bounds`, `visible`, `zoomed`
and `index`. `count of windows` includes hidden windows, so
count documents, not windows, to see what is open. Wrap scripts in `with timeout of N seconds`.

## Finding this guide from the app

Gloss carries this guide and the authoring reference inside the app, so they always match the
version installed:

```sh
osascript -e 'tell application "Gloss" to get agent guide'
```

The complete scripting dictionary is `sdef /Applications/Gloss.app` (or `scripts/gloss dictionary`).
