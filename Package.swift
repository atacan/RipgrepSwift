// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Ripgrep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Ripgrep",
            targets: ["Ripgrep"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "CRipgrep",
            path: "Artifacts/CRipgrep.xcframework"
        ),

        .target(
            name: "Ripgrep",
            dependencies: ["CRipgrep"]
        ),

        .testTarget(
            name: "RipgrepTests",
            dependencies: ["Ripgrep"]
        ),
    ]
)
