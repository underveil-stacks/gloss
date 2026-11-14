#!/usr/bin/env bash
# Fuzzes the code that takes hostile input.
#
#   scripts/fuzz.sh                 both targets, 60 seconds each
#   scripts/fuzz.sh sanitizer 600   one target, for ten minutes
#
# Xcode's own toolchain does not include the Swift fuzzer. On a Mac this
# script uses an open-source toolchain from swift.org instead, which must
# match the installed SDK's Swift version:
#
#   brew install swiftly && swiftly init --no-modify-profile --skip-install
#   swiftly install 6.4.0
#
# CI runs the same script on Linux.
#
# Targets: sanitizer (HTMLSanitizer alone), render (the whole Markdown
# pipeline, including the C parser). A crash or a failed check stops the run
# and leaves the input that caused it in Fuzz/ as a crash-* file. New inputs
# that reach new code are kept in Fuzz/corpus/.
set -euo pipefail
cd "$(dirname "$0")/.."

targets=("${1:-sanitizer}")
[[ $# -eq 0 ]] && targets=(sanitizer render)
seconds="${2:-60}"

if [[ "$(uname)" == "Darwin" ]]; then
  toolchain="$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain"
  if [[ ! -f "$toolchain/Info.plist" ]]; then
    echo "error: no swift.org toolchain found. Xcode's toolchain cannot build the fuzzer; see the top of this script." >&2
    exit 1
  fi
  TOOLCHAINS="$(plutil -extract CFBundleIdentifier raw "$toolchain/Info.plist")"
  export TOOLCHAINS
fi

swift build -c release --package-path Fuzz \
  -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library

bin="$(swift build -c release --package-path Fuzz --show-bin-path)"
cd Fuzz
for target in "${targets[@]}"; do
  case "$target" in
    sanitizer) exe=SanitizerFuzz ;;
    render) exe=RenderFuzz ;;
    *) echo "unknown target: $target (sanitizer, render)" >&2; exit 2 ;;
  esac
  echo "== fuzzing $target for ${seconds}s"
  log="$(mktemp)"
  # Swift's own crash reporter is switched off: the fuzzer reports the crash
  # and saves the input, and the reporter can stall under the sanitizer.
  SWIFT_BACKTRACE=enable=no "$bin/$exe" "corpus/$target" \
    -max_total_time="$seconds" -max_len=4096 -timeout=20 -print_final_stats=1 2>&1 | tee "$log"
  # A run that executed nothing proves nothing, however it exits.
  if ! grep -Eq 'Done [1-9][0-9]* runs' "$log"; then
    echo "error: the $target fuzzer did not report any executed runs." >&2
    exit 1
  fi
done
