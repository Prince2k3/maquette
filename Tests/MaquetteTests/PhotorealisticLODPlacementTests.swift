import CoreLocation
import Foundation
import RealityKit
import Testing
@testable import Maquette

private struct SurfaceFixtureProvider: Tiles3DProvider {
    var attribution: String { "Surface fixture" }
    func fetchTileset() async throws -> Data {
        Data("""
        {"asset":{"version":"1.1"},"geometricError":10,"root":{
          "boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},
          "geometricError":10,"refine":"REPLACE","content":{"uri":"parent.glb"},
          "children":[{"boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},
          "geometricError":0,"content":{"uri":"child.glb"}}]}}
        """.utf8)
    }
    func fetchTileContent(uri: String) async throws -> Data {
        Self.glb(height: uri == "parent.glb" ? 10 : 20)
    }
    static func glb(height: Float) -> Data {
        // At lat/lon zero ECEF offsets (up,east,north) become local (east,up,south).
        let positions: [Float] = [height, -50, 50, height, 50, 50, height, 0, -50]
        var binary = positions.withUnsafeBytes { Data($0) }
        let indices: [UInt16] = [0, 1, 2]
        binary.append(indices.withUnsafeBytes { Data($0) })
        while !binary.count.isMultiple(of: 4) { binary.append(0) }
        var json = Data("""
        {"asset":{"version":"2.0"},"extensions":{"CESIUM_RTC":{"center":[6378137,0,0]}},
        "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"mode":4}]}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
        "buffers":[{"byteLength":\(binary.count)}]}
        """.utf8)
        while !json.count.isMultiple(of: 4) { json.append(32) }
        var data = Data()
        func word(_ value: UInt32) { var value = value.littleEndian; data.append(Data(bytes: &value, count: 4)) }
        word(0x46546C67); word(2); word(UInt32(28 + json.count + binary.count))
        word(UInt32(json.count)); word(0x4E4F534A); data.append(json)
        word(UInt32(binary.count)); word(0x004E4942); data.append(binary)
        return data
    }
}

private actor DelayedSurfaceProvider: Tiles3DProvider {
    nonisolated let attribution = "Delayed fixture"
    private var request: CheckedContinuation<Data, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func fetchTileset() async throws -> Data {
        let data = try await SurfaceFixtureProvider().fetchTileset()
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"geometricError\":10", with: "\"geometricError\":10000").utf8)
    }
    func fetchTileContent(uri: String) async throws -> Data {
        if uri == "parent.glb" { return SurfaceFixtureProvider.glb(height: 10) }
        return try await withCheckedThrowingContinuation { continuation in
            request = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitForChild() async {
        if request != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishChild() { request?.resume(returning: SurfaceFixtureProvider.glb(height: 20)); request = nil }
}

@Suite("Photorealistic LOD surface invalidation") @MainActor
struct PhotorealisticLODPlacementTests {
    private let center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private var boundary: DioramaBoundary { .init(vertices: [.init(-20, -20), .init(20, -20), .init(20, 20), .init(-20, 20)]) }

    @Test func loaderSnapshotsUnclippedEntityPlacementExactly() async throws {
        let converter = ECEFConverter(origin: center)
        let loader = Tile3DLoader(provider: SurfaceFixtureProvider(), ecefConverter: converter)
        let loaded = try #require(try await loader.loadTileFromData(SurfaceFixtureProvider.glb(height: 12), uri: "fixture", transform: nil))
        #expect(loaded.surface.positions[0] == SIMD3<Float>(-50, 12, -50))
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [loaded.surface], scale: 0.5, datum: 10, pan: .init(1, 2))
        #expect(snapshot.surface.surfaceY(atX: -1, z: -2) == 1)
    }

    @Test func queriesContainEnabledLODOnlyAndRevisionStaysStableWhenNothingChanges() async throws {
        let manager = Tiles3DLODManager(provider: SurfaceFixtureProvider(), ecefConverter: .init(origin: center),
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let coarseRevision = manager.surfaceRevision
        #expect(manager.visibleSurfaceGeometry.count == 1)
        #expect(manager.visibleSurfaceGeometry.flatMap(\.positions).allSatisfy { abs($0.y - 10) < 0.0001 })
        manager.screenSpaceErrorThreshold = 0.01
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        #expect(root.children.count == 2) // The ancestor remains resident, but never queryable.
        #expect(manager.visibleSurfaceGeometry.count == 1)
        #expect(manager.visibleSurfaceGeometry.flatMap(\.positions).allSatisfy { abs($0.y - 20) < 0.0001 })
        #expect(manager.surfaceRevision > coarseRevision)
        let refinedRevision = manager.surfaceRevision
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        #expect(manager.surfaceRevision == refinedRevision)
        let moved = DioramaBoundary(vertices: boundary.vertices.map { $0 + SIMD2(200, 0) })
        manager.setClipPrism(BoundaryPrism(boundary: moved, scale: 1))
        #expect(manager.visibleSurfaceGeometry.isEmpty)
        #expect(manager.surfaceRevision > refinedRevision)
    }

    @Test func panInvalidatesPendingSnapshotAndStaleCompletionCannotRestoreIt() async throws {
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 100,
            physicalSize: 40, boundary: boundary, style: .init(), panRange: 1)
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        // The first index build is still pending on return. Pan immediately and supersede its key.
        entity.setPanOffset(.init(100, 0))
        #expect(entity.surfaceSnapshot == nil)
        await entity.waitForSurface()
        let snapshot = try #require(entity.surfaceSnapshot)
        #expect(snapshot.surface.surfaceY(atX: 0, z: 0) == nil)
        #expect(entity.surfaceDiagnostic == nil)
    }
    @Test func visibleSetInvalidatesSynchronouslyWhileNextFetchIsSuspended() async throws {
        let provider = DelayedSurfaceProvider()
        let entity = try await Tiles3DEntity(provider: provider, center: center, radiusMeters: 100,
            physicalSize: 40, boundary: boundary, style: .init(), panRange: 1)
        _ = await entity.updateLOD(cameraPosition: .init(0, 100_000_000, 100_000_000), screenHeight: 1000, fov: 1)
        await entity.waitForSurface()
        #expect(entity.surfaceSnapshot?.surface.surfaceY(atX: 0, z: 0) != nil)
        var notified = false
        entity.onSurfaceChange = { notified = true }
        let refining = Task { await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1) }
        await provider.waitForChild()
        #expect(notified)
        #expect(entity.surfaceSnapshot?.surface.surfaceY(atX: 0, z: 0) == nil)
        await provider.finishChild()
        _ = await refining.value
        await entity.waitForSurface()
        #expect(entity.surfaceSnapshot?.surface.surfaceY(atX: 0, z: 0) != nil)
    }

    @Test func completedSurfaceSnapshotPublishesThroughStoreIntoLiveContent() async throws {
        let configuration = DioramaConfiguration(center: center, radiusMeters: 100,
            shape: .rectangular(width: 40, depth: 40), physicalSize: 40,
            presentation: .photorealistic(provider: SurfaceFixtureProvider()))
        let store = DioramaStore(configuration: configuration)
        await store.load()
        let root = try #require(store.dioramaEntity as? DioramaEntity)
        let tiles = try #require(root.tiles3D)
        store.applyContent(DioramaContentGroup { DioramaMarker("Live", coordinate: Coordinate(center), id: "live") })
        #expect(root.markerEntities["live"] == nil)
        _ = await tiles.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await tiles.waitForSurface()
        #expect((store.projection as? EllipsoidProjection)?.surface != nil)
        #expect(root.markerEntities["live"]?.isEnabled == true)
    }

}
