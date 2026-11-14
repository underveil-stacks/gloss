#!/usr/bin/env bash
# Builds, signs, notarizes and staples a release disk image.
#
#   scripts/release.sh                 full release
#   scripts/release.sh --skip-notarize build and sign only
#
# Needs: Xcode, xcodegen, create-dmg, a "Developer ID Application" certificate
# in the keychain, and a notarytool keychain profile (default: gloss-notary):
#
#   xcrun notarytool store-credentials gloss-notary
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${GLOSS_NOTARY_PROFILE:-gloss-notary}"
IDENTITY="Developer ID Application"
NOTARIZE=1
[[ "${1:-}" == "--skip-notarize" ]] && NOTARIZE=0

# A beta Xcode's build number ends in a lowercase letter.
xcode_build="$(xcodebuild -version | awk '/Build version/ {print $3}')"
if [[ "$xcode_build" =~ [a-z]$ && "${GLOSS_ALLOW_BETA_TOOLCHAIN:-0}" != "1" ]]; then
  echo "error: Xcode build $xcode_build is a beta. Releases are built with a GA Xcode." >&2
  echo "       Set GLOSS_ALLOW_BETA_TOOLCHAIN=1 for a dry run that will not be published." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: the working tree has uncommitted changes." >&2
  exit 1
fi

xcodegen generate
rm -rf build/Gloss.xcarchive
xcodebuild -project Gloss.xcodeproj -scheme Gloss -configuration Release \
  -derivedDataPath build -archivePath build/Gloss.xcarchive archive

scripts/unregister-builds.sh
APP="build/Gloss.xcarchive/Products/Applications/Gloss.app"
codesign --verify --deep --strict --verbose=2 "$APP"
if ! lipo -archs "$APP/Contents/MacOS/Gloss" | grep -qx "arm64"; then
  echo "error: expected an arm64-only binary." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"

mkdir -p dist
DMG="dist/Gloss-$VERSION.dmg"
rm -f "$DMG"
create-dmg \
  --volname "Gloss" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Gloss.app" 140 180 \
  --app-drop-link 400 180 \
  --codesign "$IDENTITY" \
  "$DMG" "$STAGING"

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo "Skipped notarization: this image will be refused by Gatekeeper on another Mac."
fi

# The agent skill, for assistants that install skills from a zip.
SKILL_ZIP="dist/gloss-skill-$VERSION.zip"
rm -f "$SKILL_ZIP"
git archive --format=zip -o "$SKILL_ZIP" HEAD:skills gloss

shasum -a 256 "$DMG" "$SKILL_ZIP"
