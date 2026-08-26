#!/usr/bin/env bash
# Runs every validation step: Rust formatting, linting, and tests, then the
# XCFramework build, then the Swift build and test suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> cargo fmt --check"
(cd "$SCRIPT_DIR/../Native/ripgrep-ffi" && cargo fmt --check)

echo "==> cargo clippy"
(cd "$SCRIPT_DIR/../Native/ripgrep-ffi" && cargo clippy --all-targets -- -D warnings)

echo "==> cargo test"
(cd "$SCRIPT_DIR/../Native/ripgrep-ffi" && cargo test)

echo "==> build XCFramework"
"$SCRIPT_DIR/build-xcframework.sh"

# Swift steps resolve CRipgrep from the freshly built framework instead of
# downloading the GitHub Release asset. SwiftPM requires the path to be
# relative to the package root.
cd "$SCRIPT_DIR/.."
export RIPGREP_XCFRAMEWORK_PATH="Artifacts/CRipgrep.xcframework"

echo "==> swift build"
swift build

echo "==> swift test"
swift test

echo "All checks passed."
