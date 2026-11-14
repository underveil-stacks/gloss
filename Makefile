.PHONY: project build test core-test check release clean

DERIVED := build
XCODEBUILD := xcodebuild -project Gloss.xcodeproj -scheme Gloss -derivedDataPath $(DERIVED)

project:
	xcodegen generate

# Unsigned, so it works on a machine without the signing key.
build: project
	$(XCODEBUILD) -configuration Debug CODE_SIGNING_ALLOWED=NO build
	scripts/unregister-builds.sh

test: project
	$(XCODEBUILD) -configuration Debug CODE_SIGNING_ALLOWED=NO test
	scripts/unregister-builds.sh

core-test:
	swift test --package-path Packages/GlossCore

# Run before opening a pull request: CI covers only core-test.
check: core-test test

release:
	scripts/release.sh

clean:
	rm -rf $(DERIVED) dist Gloss.xcodeproj
