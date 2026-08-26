#!/usr/bin/env bash
# Packages Artifacts/CRipgrep.xcframework into Release/CRipgrep.xcframework.zip,
# prints the SwiftPM checksum, and shows the binaryTarget snippet to paste
# into Package.swift after uploading the zip to GitHub Releases.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
RELEASE_DIR="$ROOT_DIR/Release"
XCFRAMEWORK="$ARTIFACTS_DIR/CRipgrep.xcframework"
ZIP_PATH="$RELEASE_DIR/CRipgrep.xcframework.zip"
VERSION="${1:-0.1.2}"
REPOSITORY="${2:-atacan/RipgrepSwift}"
ASSET_URL="https://github.com/$REPOSITORY/releases/download/$VERSION/CRipgrep.xcframework.zip"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "Missing $XCFRAMEWORK"
  echo "Run ./Scripts/build-xcframework.sh first."
  exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK" "$ZIP_PATH"

CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"

cat <<EOF
Created:
  $ZIP_PATH

SwiftPM checksum:
  $CHECKSUM

Upload the zip to GitHub Releases (usually under tag $VERSION):

  gh release create $VERSION "$ZIP_PATH" --title "$VERSION" --notes "..."

Then use this binary target in Package.swift:

.binaryTarget(
  name: "CRipgrep",
  url: "$ASSET_URL",
  checksum: "$CHECKSUM"
)
EOF
