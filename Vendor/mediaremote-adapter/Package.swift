// swift-tools-version:6.2
// Vendored from MediaRemoteAdapter 0.1.4 (commit b6346e062231d61f70dd025ff98ca56714fc5c12).
// Source behavior is unchanged. The tools-version declaration and OpenSoftLinking
// dependency location are adapted for the Xcode 26.2 toolchain.

import PackageDescription

let package = Package(
    name: "MediaRemoteAdapter",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "MediaRemoteAdapter",
            type: .dynamic,
            targets: ["MediaRemoteAdapter"]),
    ],
    dependencies: [
        .package(path: "../OpenSoftLinking"),
    ],
    targets: [
        .target(
            name: "MediaRemoteAdapter",
            dependencies: ["CIMediaRemote"],
            resources: [
                .copy("Resources/run.pl")
            ]
        ),
        .target(
            name: "CIMediaRemote",
            dependencies: [
                .product(name: "OpenSoftLinking", package: "OpenSoftLinking"),
            ]
        )
    ],
    swiftLanguageModes: [.v5],
)
