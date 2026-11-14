#!/usr/bin/env bash
# Xcode registers every app it builds with Launch Services, which may then open
# a Markdown file in a copy from the build folder instead of the installed one.
# The build-folder copy is unsigned, shows a blank Dock icon, and changes under
# the reader's feet. This takes the build folder's copies back out.
set -euo pipefail
cd "$(dirname "$0")/.."

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] || exit 0

find build -name Gloss.app -type d -prune 2>/dev/null | while read -r app; do
  "$lsregister" -u "$PWD/$app" >/dev/null 2>&1 || true
done
