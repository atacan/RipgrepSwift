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
        url: "https://github.com/atacan/RipgrepSwift/releases/download/0.1.2/CRipgrep.xcframework.zip",
        checksum: "9ea2aa092a0917f66f945765b1669be64d1dd1c497c9c4d5dad7a77527bc2722"
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
