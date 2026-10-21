import CoreLocation
import Foundation
import RealityKit
import Testing
@testable import Maquette

/// Records what the traversal asks for, and refuses every tile so nothing ever becomes covered.
///
/// Refusing is the point: it holds the traversal in the state where ancestors stand in for
/// children, which is the only state these tests are about.
private actor RecordingProvider: Tiles3DProvider {
    private let tileset: TilesetJSON
    private(set) var requested: Set<String> = []

    init(tileset: TilesetJSON) {
        self.tileset = tileset
    }

    nonisolated var attribution: String { "Test" }

    func fetchTileset() async throws -> Data {
        try JSONEncoder().encode(tileset)
    }

    func fetchTileContent(uri: String) async throws -> Data {
        requested.insert(uri)
        throw Refused()
    }

    private struct Refused: Error {}
}

@Suite("3D Tiles LOD Traversal Tests")
@MainActor
struct Tiles3DLODManagerTests {
    private static let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
    private static let radiusMeters: Double = 1400
    private static let threshold: Double = 16

    /// A middle-tile error that refines but stays within the stand-in bound from this camera.
    private static let nearbyError: Double = 100
    /// A middle-tile error far enough past the bound that it must not stand in.
    private static let farError: Double = 9000

    /// A tileset three levels deep, all covering the diorama, differing only in geometric error.
    ///
    /// The root's error is planetary, the leaf's is a metre, and the middle's is whatever the test
    /// sets — so which of them the traversal is willing to draw is the only thing under test.
    private static func tileset(middleGeometricError: Double) -> TilesetJSON {
        let west = center.longitude * .pi / 180 - 0.0004
        let east = center.longitude * .pi / 180 + 0.0004
        let south = center.latitude * .pi / 180 - 0.0002
        let north = center.latitude * .pi / 180 + 0.0002

        let json = """
        {
          "asset": { "version": "1.1" },
          "geometricError": 1e12,
          "root": {
            "boundingVolume": { "region": [-3.14159, -1.5707, 3.14159, 1.5707, 0, 4000] },
            "geometricError": 1e12,
            "refine": "REPLACE",
            "content": { "uri": "planet.glb" },
            "children": [{
              "boundingVolume": { "region": [\(west), \(south), \(east), \(north), 1000, 3000] },
              "geometricError": \(middleGeometricError),
              "content": { "uri": "middle.glb" },
              "children": [{
                "boundingVolume": { "region": [\(west), \(south), \(east), \(north), 1000, 3000] },
                "geometricError": 1,
                "content": { "uri": "leaf.glb" }
              }]
            }]
          }
        }
        """
        return try! JSONDecoder().decode(TilesetJSON.self, from: Data(json.utf8))
    }

    private static func run(middleGeometricError: Double) async -> Set<String> {
        let provider = RecordingProvider(tileset: tileset(middleGeometricError: middleGeometricError))
        let manager = Tiles3DLODManager(
            provider: provider,
            ecefConverter: ECEFConverter(origin: center),
            center: center,
            radiusMeters: radiusMeters
        )
        manager.screenSpaceErrorThreshold = threshold
        try! await manager.start()
        _ = await manager.update(
            parentEntity: Entity(),
            cameraPosition: SIMD3<Float>(0, 3000, 3000),
            screenHeight: 1000,
            fov: 60 * .pi / 180
        )
        return await provider.requested
    }

    @Test("The leaf the camera actually wants is requested")
    func requestsTheDetailItSelected() async {
        // Also a minimal optimized-build regression: the actor provider hops executors and
        // throws for each child request. Returning an async closure from the fetch factory
        // aborted swift_task_dealloc in Swift 6.4 even when this test ran alone. Keep Release
        // coverage so draining failed child tasks is verified, not just request selection.
        let requested = await Self.run(middleGeometricError: Self.nearbyError)
        #expect(requested.contains("leaf.glb"))
    }

    @Test("An ancestor far coarser than the detail being asked for never stands in")
    func farCoarserAncestorIsNeverDrawn() async {
        // Google's tree starts at planetary scale, so there is always an ancestor willing to cover
        // for a leaf in flight. Drawing one that is levels too coarse does not soften the model, it
        // relocates it: on Half Dome the tile that stood in bottomed out 135 m below every other
        // tile on screen, and since the tray tracks the lowest visible geometry, the model ended up
        // floating in a gap above it.
        let requested = await Self.run(middleGeometricError: Self.nearbyError)
        #expect(!requested.contains("planet.glb"))
    }

    @Test("An ancestor within a couple of levels still stands in")
    func nearbyAncestorStillStandsIn() async {
        // The bound exists to exclude the useless, not to stop standing in. A tile one or two levels
        // up is a softer version of the same ground, which is what progressive refinement looks
        // like, and is exactly what should cover for a leaf still in flight.
        let requested = await Self.run(middleGeometricError: Self.nearbyError)
        #expect(requested.contains("middle.glb"))
    }

    @Test("The bound follows the error the camera sees, not the tile's depth in the tree")
    func boundFollowsScreenSpaceErrorNotDepth() async {
        // Same shape of tileset, and the middle tile is still the leaf's immediate parent. Only its
        // error changed — being one step up the tree buys it nothing.
        let requested = await Self.run(middleGeometricError: Self.farError)
        #expect(requested.contains("leaf.glb"))
        #expect(!requested.contains("middle.glb"))
    }
}
