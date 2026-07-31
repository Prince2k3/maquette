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
        ),
        // Compiles against the library the way a consumer does — a plain `import Maquette`, no
        // @testable — so an access-control change that breaks the public API breaks this target
        // rather than shipping silently. Every other test file is @testable and proves nothing
        // about visibility.
        .testTarget(
            name: "MaquetteAPITests",
            dependencies: ["Maquette"],
            path: "Tests/MaquetteAPITests"
        )
    ]
)
