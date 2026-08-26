#!/usr/bin/env bash
# Builds the Rust FFI crate into static libraries for the supported
# Apple targets. Output: Native/ripgrep-ffi/build/<target>/libripgrep_ffi.a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/../Native/ripgrep-ffi"
TARGETS=(
    aarch64-apple-darwin
    x86_64-apple-darwin
)

cd "$CRATE_DIR"

for target in "${TARGETS[@]}"; do
    if ! rustup target list --installed | grep -q "^$target$"; then
        echo "Installing missing Rust target: $target"
        rustup target add "$target"
    fi
    echo "Building ripgrep-ffi for $target (release)"
    cargo build --release --target "$target"
done

echo "Static libraries:"
for target in "${TARGETS[@]}"; do
    ls -l "target/$target/release/libripgrep_ffi.a"
done
