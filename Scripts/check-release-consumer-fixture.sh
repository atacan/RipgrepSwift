#!/usr/bin/env bash
# Pre-release validation for the release-consumer fixture.
#
# Compiles and RUNS the exact Swift fixture that
# Scripts/verify-release-consumer.sh ships to release consumers — but
# against the locally built XCFramework via a path dependency, so it works
# before any tag or release asset exists. Catches fixture bugs (like
# invalid Swift syntax) before a tag is created instead of after the
# release is published.
#
# Requires Artifacts/CRipgrep.xcframework (run ./Scripts/build-xcframework.sh,
# or just ./Scripts/verify.sh which calls this).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/release-consumer/main.swift"
XCFRAMEWORK="$ROOT_DIR/Artifacts/CRipgrep.xcframework"

if [[ ! -f "$FIXTURE" ]]; then
    echo "FAIL: consumer fixture not found at $FIXTURE" >&2
    exit 1
fi
if [[ ! -d "$XCFRAMEWORK" ]]; then
    echo "FAIL: missing $XCFRAMEWORK" >&2
    echo "Run ./Scripts/build-xcframework.sh first." >&2
    exit 1
fi

# SwiftPM derives the path dependency's identity from the directory name.
PACKAGE_IDENTITY="$(basename "$ROOT_DIR")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ripgrep-fixture-check.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

CONSUMER="$WORK_DIR/consumer"
mkdir -p "$CONSUMER/Sources/Consumer"
cp "$FIXTURE" "$CONSUMER/Sources/Consumer/main.swift"

cat > "$CONSUMER/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixtureCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "$ROOT_DIR"),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "Ripgrep", package: "$PACKAGE_IDENTITY")]
        ),
    ]
)
EOF

echo "==> Compiling + running release-consumer fixture against local XCFramework"
(
    cd "$CONSUMER"
    # The local framework must win over any remote binary target; this is
    # the only sanctioned use of the override here because no published
    # artifact is required. SwiftPM requires the path to be relative to
    # the dependency package's root, exactly like Scripts/verify.sh.
    export RIPGREP_XCFRAMEWORK_PATH="Artifacts/CRipgrep.xcframework"
    swift build --cache-path "$WORK_DIR/swiftpm-cache" --scratch-path "$WORK_DIR/.build"
    "$WORK_DIR/.build/debug/Consumer"
)

echo "PASS: release-consumer fixture compiles and runs against the local build"
