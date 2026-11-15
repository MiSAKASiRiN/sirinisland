// swift-tools-version: 6.2
// Vendored from OpenSoftLinking 0.1.0 (commit bdc30a77b63b4209acdb4fe777b57a9c83cabc7a).
// Only the tools-version declaration is lowered from 6.3 to 6.2 for Xcode 26.2.

import PackageDescription

let package = Package(
    name: "OpenSoftLinking",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
        .macCatalyst(.v13),
    ],
    products: [
        .library(
            name: "OpenSoftLinking",
            targets: ["OpenSoftLinking"]
        ),
    ],
    targets: [
        .target(
            name: "OpenSoftLinking",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
