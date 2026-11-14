# Engineering notes

Things learned while building Gloss that are not obvious from the code. Each entry says how it was
established.

## Verified

- **The Swift-native WebKit API is enough for the page.** `WebPage`, `WebView`, `URLSchemeHandler`
  and `WebPage.NavigationDeciding`. The one exception is printing: only the older `WKWebView` can
  make a paginated print job, so `PrintController` loads the page a second time into one, served
  by the same `PageStore`.
- **A content security policy sent as a response header is enforced on a custom scheme.** The
  hostile-page test fails on its script, handler and remote-image checks when the header is
  removed.
- **SwiftUI's viewing document group does not reload a file that changes on disk.** Gloss watches
  the file's directory itself. A moved file is followed, because macOS hands the document its new
  URL. Tested in the running app: in-place write, atomic replace, move, delete.
- **Mermaid and KaTeX run under the policy**, given `style-src 'unsafe-inline'`, which a bundle
  asks for with `inlineStyles`. Neither needs `eval`. They are loaded only for documents that use
  them, so other pages keep the strict style policy; a test checks that.
- **Developer ID signing, the hardened runtime and notarization work with the release script.**
  An App Store Connect API key works as the `notarytool` credential.
- **The stock AppleScript `save` verb raises a blocking alert on a viewer document** (it cannot
  write). The dictionary carries a trimmed Standard Suite instead; a raw save event is refused.
- **Gloss restores the previous session's documents on launch**, as Mac document apps do. Scripts
  must refer to documents by name.

- **The sanitizer holds up under mutation and fuzzing.** Each of its 60 protections was disabled in
  turn and a test failed every time. The fuzzers have run millions of inputs against it and
  against the whole pipeline, locally and in CI, with no finding.
- **Typing into a page field marked the file as edited.** The web view's undo actions reached the
  document's undo manager, SwiftUI counted each as an edit, and macOS tried to autosave the file
  and showed its "could not be autosaved" sheet on close. Turning the document's undo manager off
  (`CloseGuard.attach`) stopped it; the window then takes its undo manager from the guard. Found
  and confirmed in the running app; the delegate hook alone was not enough, because SwiftUI's
  hosting view hands out the document's undo manager itself.
- **The close guard works in the running app**: ⌘W with unexported answers shows the sheet, its
  Cancel, Copy and Close and Close Without Exporting buttons do what they say, an untouched form
  closes without asking, and ⌘Q asks once for all windows. Checked with System Events
  (2026-11-13, macOS 27.3).
- **Raw HTML cannot forge what Gloss adds after sanitizing.** Heading ids, alerts and highlighted
  code are attached by `data-sourcepos`; that attribute name is spoiled in raw HTML before
  rendering, and a test fails if that step is removed.

## How the sanitizer differs from GitHub's

Modelled on GitHub's allowlist, with these differences:

- Also allowed: `picture`, `source`, `section`, `id`, a filtered `class`, `srcset` and `sizes`,
  and form controls: `input` (not `password`, `file`, `hidden`, `image` or the button types),
  `textarea`, `select`, `option`, `optgroup`, `label`, `fieldset` and `legend`. `form` and
  `button` are still removed. cmark-gfm's tagfilter is not attached, because it escapes
  `textarea`; the sanitizer already removes everything tagfilter covers.
- Not allowed: `action`, and the `xmpp`, `irc`, `ircs` and GitHub desktop link schemes.
- Every `id` and `name` written in raw HTML is prefixed `user-content-`, and a `#fragment` link is
  prefixed to match only when the document defines that target. Footnote ids (`fn-…`, `fnref-…`)
  are left alone, so a page script must never look up an element by an id of that shape.
- A raw `<a id="intro">` and a heading "Intro" can both exist; `#intro` then goes to the heading's
  unprefixed id.
- An unclosed `<svg>`, `<object>`, `<template>` or `<title>` removes everything to the end of the
  document, as a browser would.
- A relative link containing an unknown named character reference before its first `/`, `?` or `#`
  is refused, because it could hide a scheme. Only hand-written HTML is affected.

## Not verified

- **SwiftUI's document window still sends a close through its delegate.** The close guard stands in
  front of a delegate SwiftUI owns; tests check the guard against a plain window, and the guard
  puts itself back (and logs an error) if the delegate is replaced, but only the running app shows
  that ⌘W reaches it. **Release check:** type an answer, press ⌘W, and see the sheet; repeat after
  each macOS update.

- **Quick Look.** The extension is embedded, signed, sandboxed and registered with the system
  (`pluginkit` lists it as enabled for `com.apple.quicklook.preview`), but `qlmanage -p` on a
  Markdown file showed the system's plain-text preview and the extension was never launched. The
  extension is missing from `pluginkit`'s default listing for that extension point and appears
  only with `-A -D`, which suggests the system does not consider it eligible. It was tested from
  a build folder; the untested hypothesis is that an extension is only eligible when its app is
  in an Applications folder. Try it from an installed, notarized copy before changing code.
- **Tabs and Open Recent.** They come from the platform and have not been exercised by a test;
  scripting the menus needs Accessibility permission.
- **A second Mac.** The notarized image has only been assessed on the machine that built it.

## Known limits

- Math written as a lone `$…$` is not rendered, by choice. Underscores inside `$$…$$` can be
  taken as emphasis by the Markdown parser before the math add-on sees them; a `math` code block
  avoids that.
- The default-viewer prompt appears only when Gloss runs from an Applications folder.
- Form answers are kept only in the window. They are carried across a re-render, a reload and
  printing, and closing or quitting asks first, but Gloss never saves a draft.
- Print uses the theme's print stylesheet or Gloss's own; export as PDF is a single continuous
  page of the screen rendering.
