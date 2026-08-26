// swift-tools-version: 6.0
import Foundation
import PackageDescription

let cRipgrepTarget: Target

if let localXCFrameworkPath = ProcessInfo.processInfo.environment["RIPGREP_XCFRAMEWORK_PATH"] {
    cRipgrepTarget = .binaryTarget(
        name: "CRipgrep",
        path: localXCFrameworkPath
    )
} else {
    cRipgrepTarget = .binaryTarget(
        name: "CRipgrep",
        url: "https://github.com/atacan/RipgrepSwift/releases/download/0.1.0/CRipgrep.xcframework.zip",
        checksum: "4baad5dc539ee08ad0f5b1d015eca90b26ff35876d883be5e838ccf6e80618c2"
    )
}

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
        cRipgrepTarget,

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
