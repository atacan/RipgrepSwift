#!/usr/bin/env bash
# Builds the Rust static libraries and assembles them into the macOS
# XCFramework consumed by Package.swift:
#   Artifacts/CRipgrep.xcframework
#
# Always starts from a clean output directory so stale slices cannot survive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
CRATE_DIR="$ROOT_DIR/Native/ripgrep-ffi"
OUTPUT_DIR="$ROOT_DIR/Artifacts"
XCFRAMEWORK="$OUTPUT_DIR/CRipgrep.xcframework"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

"$SCRIPT_DIR/build-rust.sh"

# 1. Create a universal (arm64 + x86_64) macOS library with lipo.
mkdir -p "$STAGING/macos"
lipo -create \
    "$CRATE_DIR/target/aarch64-apple-darwin/release/libripgrep_ffi.a" \
    "$CRATE_DIR/target/x86_64-apple-darwin/release/libripgrep_ffi.a" \
    -output "$STAGING/macos/libripgrep_ffi.a"

# 2. Associate the binary with its C header and module map.
mkdir -p "$STAGING/headers"
cp "$CRATE_DIR/include/ripgrep_ffi.h" "$STAGING/headers/"
cat > "$STAGING/headers/module.modulemap" <<'EOF'
module CRipgrep {
    header "ripgrep_ffi.h"
    export *
}
EOF

# 3. Assemble the XCFramework from scratch.
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$STAGING/macos/libripgrep_ffi.a" \
    -headers "$STAGING/headers" \
    -output "$XCFRAMEWORK"

# 4. Keep module.modulemap in both Headers/ and Modules/:
#    SwiftPM's CLI discovers it via the header include path (-I Headers),
#    while Xcode-style tooling expects Modules/.
find "$XCFRAMEWORK" -type d -name Headers | while read -r headers_dir; do
    slice_dir="$(dirname "$headers_dir")"
    if [ -f "$headers_dir/module.modulemap" ]; then
        mkdir -p "$slice_dir/Modules"
        cp "$headers_dir/module.modulemap" "$slice_dir/Modules/module.modulemap"
    fi
done

echo "Created $XCFRAMEWORK:"
find "$XCFRAMEWORK" -maxdepth 3 | sed 's/^/  /'
