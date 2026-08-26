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
        url: "https://github.com/atacan/RipgrepSwift/releases/download/0.1.1/CRipgrep.xcframework.zip",
        checksum: "29b6ed37d978c3ffc0e2737033bae2570470bcf2e2e264676f09c2e2edabaa09"
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
