// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MaquetteAPIContract",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "MaquetteNext", dependencies: [.product(name: "Maquette", package: "Maquette")]),
        .testTarget(name: "MaquetteNextTests", dependencies: ["MaquetteNext"])
    ]
)
