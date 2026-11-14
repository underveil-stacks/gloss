#!/usr/bin/env bash
# Copies the JavaScript libraries Gloss ships into the app, at the versions
# recorded in third-party/package.json.
#
# To update a library: change its version in third-party/package.json, run
# `npm install --package-lock-only --ignore-scripts` in third-party/, run this
# script, then `make check`.
set -euo pipefail
cd "$(dirname "$0")/.."

version() { node -e "console.log(require('./third-party/package.json').dependencies['$1'])"; }
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

HLJS="$(version highlight.js)"
KATEX="$(version katex)"
MERMAID="$(version mermaid)"
CDN="https://cdn.jsdelivr.net/npm"

# highlight.js publishes its browser build separately from the npm package.
vendor="App/Resources/vendor"
fetch "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/$HLJS/highlight.min.js" "$vendor/highlight.min.js"
fetch "https://raw.githubusercontent.com/highlightjs/highlight.js/$HLJS/LICENSE" "$vendor/highlight.LICENSE"

mermaid="App/Bundles/mermaid.glossbundle"
fetch "$CDN/mermaid@$MERMAID/dist/mermaid.min.js" "$mermaid/mermaid.min.js"
fetch "$CDN/mermaid@$MERMAID/LICENSE" "$mermaid/LICENSE-mermaid"

math="App/Bundles/math.glossbundle"
fetch "$CDN/katex@$KATEX/dist/katex.min.js" "$math/katex.min.js"
fetch "$CDN/katex@$KATEX/dist/katex.min.css" "$math/katex.min.css"
fetch "$CDN/katex@$KATEX/dist/contrib/auto-render.min.js" "$math/auto-render.min.js"
fetch "$CDN/katex@$KATEX/LICENSE" "$math/LICENSE-katex"
rm -rf "$math/fonts"
mkdir -p "$math/fonts"
# Only the woff2 fonts: every browser engine Gloss runs on supports them.
for font in $(grep -o 'fonts/[A-Za-z0-9_-]*\.woff2' "$math/katex.min.css" | sort -u); do
  fetch "$CDN/katex@$KATEX/dist/$font" "$math/$font"
done

echo "highlight.js $HLJS, mermaid $MERMAID, katex $KATEX"
