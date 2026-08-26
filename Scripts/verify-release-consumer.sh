#!/usr/bin/env bash
# Verifies what a real SwiftPM consumer sees with NO environment override:
#
#   fresh directory
#       -> executable package depending on RipgrepSwift at the given ref
#       -> no RIPGREP_XCFRAMEWORK_PATH
#       -> SwiftPM downloads the GitHub Release CRipgrep.xcframework.zip
#          named by Package.swift's default binary target
#       -> compile + link against that downloaded binary
#       -> run a real search and exercise cancellation
#
# Usage: Scripts/verify-release-consumer.sh [ref]  (default: 0.1.1)
set -euo pipefail

REF="${1:-0.1.1}"
REPO_URL="https://github.com/atacan/RipgrepSwift.git"

if [[ -n "${RIPGREP_XCFRAMEWORK_PATH:-}" ]]; then
    echo "FAIL: RIPGREP_XCFRAMEWORK_PATH is set to '$RIPGREP_XCFRAMEWORK_PATH'." >&2
    echo "This verification must exercise the remote GitHub Release binary; unset it." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ripgrep-release-consumer.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

CONSUMER="$WORK_DIR/consumer"
mkdir -p "$CONSUMER/Sources/Consumer"

echo "==> Consumer package in fresh directory: $CONSUMER"
echo "==> Dependency: $REPO_URL @ $REF"

cat > "$CONSUMER/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReleaseConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "$REPO_URL", exact: "$REF"),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "Ripgrep", package: "RipgrepSwift")]
        ),
    ]
)
EOF

cat > "$CONSUMER/Sources/Consumer/main.swift" <<'EOF'
import Foundation
import Ripgrep

// Fixture with several matches spread across multiple files.
let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("rg-release-consumer-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
for index in 0..<3 {
    let lines = (0..<20_000).map { "line \($0) needle here\n" }.joined()
    try Data(lines.utf8).write(to: root.appendingPathComponent("file\(index).txt"))
}

// 1. A real search whose results are actually consumed.
var count = 0
for try await match in Ripgrep.search("needle", in: root) {
    precondition(match.line.contains("needle"), "unexpected line: \(match.line)")
    count += 1
    if count == 100 { break }
}
precondition(count == 100, "expected to consume 100 matches, got \(count)")

// 2. Exercise cancellation: cancel() before iteration prevents startup.
let cancelled = Ripgrep.search("needle", in: root)
cancelled.cancel()
let first = try await cancelled.makeAsyncIterator().next()
precondition(first == nil, "cancelled search must end immediately")

print("release consumer verification passed: consumed \(count) matches, cancellation clean")
EOF

cd "$CONSUMER"

# Keep every SwiftPM cache inside the throwaway directory so stale cached
# artifacts cannot satisfy resolution.
CACHE_ARGS=(
    --cache-path "$WORK_DIR/swiftpm-cache"
    --scratch-path "$WORK_DIR/.build"
)

echo "==> swift package resolve (downloads source + release XCFramework)"
swift package resolve "${CACHE_ARGS[@]}"

CHECKOUT="$WORK_DIR/.build/checkouts/RipgrepSwift"
MANIFEST="$CHECKOUT/Package.swift"
if [[ ! -f "$MANIFEST" ]]; then
    echo "FAIL: resolved checkout not found at $CHECKOUT" >&2
    exit 1
fi

echo "==> Resolved Package.swift default binary target:"
grep -A2 'url:' "$MANIFEST" | sed 's/^/    /'
if ! grep -q "releases/download/$REF/CRipgrep.xcframework.zip" "$MANIFEST"; then
    echo "FAIL: manifest does not reference the $REF release asset." >&2
    exit 1
fi

# Hard proof the *downloaded* binary carries the v0.1.1 ABI: the old 0.1.0
# binary does not contain rg_cancel_token_create. Apple's nm may refuse to
# read archives produced by recent Rust LLVM versions, so check for the
# symbol names in the archive directly; linking and running below is the
# authoritative check.
echo "==> Checking downloaded XCFramework for v0.1.1 ABI symbols"
LIBRARY="$(find "$WORK_DIR/.build" -path '*CRipgrep.xcframework*' -name 'libripgrep_ffi.a' | head -1)"
if [[ -z "$LIBRARY" ]]; then
    echo "FAIL: no libripgrep_ffi.a found among resolved artifacts." >&2
    exit 1
fi
echo "    $LIBRARY"
for symbol in _rg_cancel_token_create _rg_cancel_token_cancel _rg_cancel_token_free; do
    if ! grep -aq -- "$symbol" "$LIBRARY"; then
        echo "FAIL: downloaded binary does not contain $symbol (pre-0.1.1 ABI)." >&2
        exit 1
    fi
done
echo "    rg_cancel_token_create/cancel/free present"

echo "==> swift build"
swift build "${CACHE_ARGS[@]}"

echo "==> Running consumer executable (real search + cancellation)"
"$WORK_DIR/.build/debug/Consumer"

echo "PASS: remote-binary consumer verification succeeded for ref $REF"
