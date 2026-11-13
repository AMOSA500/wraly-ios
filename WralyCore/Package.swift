// swift-tools-version:5.9
import PackageDescription

// WralyCore holds every photography decision Wraly makes: framing, pose,
// lighting, lens and camera-setting rules. It has no dependency on UIKit,
// AVFoundation or Vision, so it can be unit-tested on any platform and
// tuned without touching camera code.
let package = Package(
    name: "WralyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WralyCore", targets: ["WralyCore"]),
    ],
    targets: [
        .target(name: "WralyCore"),
        .testTarget(name: "WralyCoreTests", dependencies: ["WralyCore"]),
    ]
)
