// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Maquette",
    platforms: [
        .visionOS(.v2),
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Maquette",
            targets: ["Maquette"]
        )
    ],
    targets: [
        .target(
            name: "Maquette",
            path: "Sources/Maquette"
        ),
        .testTarget(
            name: "MaquetteTests",
            dependencies: ["Maquette"],
            path: "Tests/MaquetteTests"
        )
    ]
)
