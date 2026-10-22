import CoreLocation
import Foundation
import RealityKit
import Testing
@testable import Maquette

private struct SurfaceFixtureProvider: Tiles3DProvider {
    var attribution: String { "Surface fixture" }
    var shear = false
    func fetchTileset() async throws -> Data {
        Data("""
        {"asset":{"version":"1.1"},"geometricError":10,"root":{
          "boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},
          \(shear ? "\"transform\":[1,0,0,0,0.5,1,0,0,0,0,1,0,0,0,0,1]," : "")
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

private actor PanMarginProvider: Tiles3DProvider {
    nonisolated let attribution = "Pan margin fixture"
    private(set) var requested: [String] = []
    private let blocksFar: Bool
    private let includesWest: Bool
    private var blocked: CheckedContinuation<Void, Never>?
    private var wasReleased = false
    init(blocksFar: Bool = false, includesWest: Bool = false) {
        self.blocksFar = blocksFar; self.includesWest = includesWest
    }
    func fetchTileset() async throws -> Data {
        let offsets = includesWest ? [0, 110, -110] : [0, 110]
        let children = offsets.map { offset in
            let name = offset == 0 ? "near" : offset > 0 ? "far" : "west"
            return """
            {"boundingVolume":{"box":[6378147,0,0,0,50,0,0,0,50,1,0,0]},
             "transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,\(offset),0,1],
             "geometricError":0,"content":{"uri":"\(name).glb"}}
            """
        }.joined(separator: ",")
        return Data("""
        {"asset":{"version":"1.1"},"geometricError":10000,"root":{
          "boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},
          "geometricError":10000,"refine":"REPLACE","children":[\(children)]}}
        """.utf8)
    }
    func fetchTileContent(uri: String) async throws -> Data {
        requested.append(uri)
        if blocksFar, !wasReleased, uri == "far.glb" {
            await withCheckedContinuation { continuation in
                blocked = continuation
            }
        }
        return SurfaceFixtureProvider.glb(height: 10)
    }
    func waitForBlockedFetch() async -> Bool {
        for _ in 0..<300 {
            if blocked != nil { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    func release() { wasReleased = true; blocked?.resume(); blocked = nil }

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

    @Test func aFinalPanDuringBlockedRefinementStillStreamsItsMargin() async throws {
        let provider = PanMarginProvider(blocksFar: true, includesWest: true)
        defer { Task { await provider.release() } }
        let entity = try await Tiles3DEntity(provider: provider, center: center, radiusMeters: 20,
            physicalSize: 40, boundary: boundary, style: .standard, panRange: 1)
        entity.requestLODUpdate(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await entity.waitForPanLODRefresh()
        #expect(await provider.requested == ["near.glb"])
        entity.setPanOffset(.init(30, 0))
        await entity.waitForPanPresentation()
        try #require(await provider.waitForBlockedFetch(), "The pan tail must start the margin fetch")
        entity.setPanOffset(.init(-30, 0))
        await entity.waitForPanPresentation()
        // Let the final tail wake while the earlier eastward fetch remains suspended.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await provider.requested == ["near.glb", "far.glb"])
        await provider.release()
        await entity.waitForPanLODRefresh()
        #expect(await provider.requested == ["near.glb", "far.glb", "west.glb"])
        #expect(entity.panOffset == SIMD2(-30, 0))
    }

    @Test func theFinalPanStreamsItsNewMarginWithoutAnotherCameraCallback() async throws {
        let provider = PanMarginProvider()
        let entity = try await Tiles3DEntity(provider: provider, center: center, radiusMeters: 20,
            physicalSize: 40, boundary: boundary, style: .standard, panRange: 1)
        entity.requestLODUpdate(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await entity.waitForPanLODRefresh()
        #expect(await provider.requested == ["near.glb"])
        entity.setPanOffset(.init(5, 0))
        await entity.waitForPanPresentation()
        entity.setPanOffset(.init(30, 0))
        await entity.waitForPanPresentation()
        // No more camera callbacks or gesture input. The scheduled tail must use offset30.
        await entity.waitForPanLODRefresh()
        #expect(await provider.requested == ["near.glb", "far.glb"])
        #expect(entity.panOffset == SIMD2(30, 0))
    }

    @Test func deferredPhotoCompletionSurvivesContentAndDrainsLatestInput() async throws {
        let configuration = DioramaConfiguration(center: center, radiusMeters: 20,
            shape: .rectangular(width: 40, depth: 40), physicalSize: 40, panRange: 1,
            presentation: .photorealistic(provider: SurfaceFixtureProvider()))
        let store = DioramaStore(configuration: configuration)
        await store.load()
        let root = try #require(store.dioramaEntity as? DioramaEntity)
        let tiles = try #require(root.tiles3D)
        _ = await tiles.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await tiles.waitForSurface()
        store.applyContent(DioramaContentGroup { DioramaCircle(center: Coordinate(center), radius: 5, id: "circle") })
        store.setPanOffset(.init(1, 0))
        #expect(tiles.isPanPresentationDeferred)
        #expect(tiles.panOffset == .zero)
        #expect(root.panPresentationCompletion != nil)
        #expect(root.finishPanPresentation() == nil)
        store.setPanOffset(.init(2, 0))
        await tiles.waitForPanPresentation()
        #expect(tiles.panOffset == SIMD2(2, 0))
        #expect(store.panOffset == tiles.panOffset)
        #expect(!store.hasPendingPan)
        #expect(root.panPresentationCompletion == nil)
        #expect((store.projection as? EllipsoidProjection)?.panOffset == tiles.panOffset)
    }

    @Test func aStaleDeferredPanCanRetryAndDrainQueuedInput() async throws {
        let configuration = DioramaConfiguration(center: center, radiusMeters: 20,
            shape: .rectangular(width: 40, depth: 40), physicalSize: 40, panRange: 1,
            presentation: .photorealistic(provider: SurfaceFixtureProvider()))
        let store = DioramaStore(configuration: configuration)
        await store.load()
        let root = try #require(store.dioramaEntity as? DioramaEntity)
        let tiles = try #require(root.tiles3D)
        _ = await tiles.updateLOD(cameraPosition: .init(0, 1e8, 1e8), screenHeight: 1000, fov: 1)
        store.setPanOffset(.init(1, 0))
        store.setPanOffset(.init(2, 0))
        #expect(root.panPresentationCompletion != nil)
        // Selection changes before the child fetch can suspend, invalidating the worker's
        // coarse candidate. The replacement must retain the deferred completion.
        _ = await tiles.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await tiles.waitForPanPresentation()
        #expect(tiles.panOffset == SIMD2(2, 0))
        #expect(store.panOffset == tiles.panOffset)
        #expect(!store.hasPendingPan)
        #expect(root.panPresentationCompletion == nil)
    }

    @Test func failedTileUploadDropsTheMismatchedRimAndUsesInstalledBounds() async throws {
        var fail = false
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 20,
            physicalSize: 40, boundary: boundary, style: .standard, panRange: 1,
            meshUpload: { buffer, vertices, indices, bounds, transfer in
                if fail { throw DioramaError.meshGenerationFailed(reason: "Injected pan growth failure") }
                return try buffer.write(vertices: vertices, indices: indices, bounds: bounds, transfer: transfer)
            })
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        entity.setPanOffset(.init(0.1, 0))
        await entity.waitForPanPresentation()
        #expect(entity.cutWall?.isEnabled == true)
        fail = true
        entity.setPanOffset(.init(1, 0))
        await entity.waitForPanPresentation()
        #expect(entity.cutWall?.isEnabled == false)
        #expect(entity.groundDatumElevation == nil)
        fail = false
        entity.setPanOffset(.init(2, 0))
        await entity.waitForPanPresentation()
        #expect(entity.groundDatumElevation != nil)
        #expect(entity.cutWall?.isEnabled == true)
    }

    @Test func failedWallUploadCannotKeepAnOldContourAfterPanCommit() async throws {
        var fail = false
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 20,
            physicalSize: 40, boundary: boundary, style: .standard, panRange: 1,
            wallUpload: { buffer, geometry in
                if fail { throw DioramaError.meshGenerationFailed(reason: "Injected rim growth failure") }
                return try buffer.write(vertices: geometry.mesh.vertices, indices: geometry.mesh.indices,
                    bounds: geometry.mesh.bounds, parts: geometry.parts)
            })
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        entity.setPanOffset(.init(0.1, 0))
        await entity.waitForPanPresentation()
        #expect(entity.cutWall?.isEnabled == true)
        fail = true
        entity.setPanOffset(.init(1, 0))
        await entity.waitForPanPresentation()
        #expect(entity.panOffset == SIMD2(1, 0))
        #expect(entity.cutWall?.isEnabled == false)
        #expect(entity.groundDatumElevation != nil)
        fail = false
        entity.setPanOffset(.init(2, 0))
        await entity.waitForPanPresentation()
        #expect(entity.cutWall?.isEnabled == true)
    }

    @Test func preparingPanDoesNotMutateVisibleSolidOrPublishQueries() async throws {
        let manager = Tiles3DLODManager(provider: SurfaceFixtureProvider(), ecefConverter: .init(origin: center),
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let before = manager.visibleSurfaceGeometry.map(\.positions), revision = manager.surfaceRevision
        let moved = DioramaBoundary(vertices: boundary.vertices.map { $0 + SIMD2(3, 0) })
        let candidate = manager.preparePan(to: BoundaryPrism(boundary: moved, scale: 1))
        #expect(manager.visibleSurfaceGeometry.map(\.positions) == before)
        #expect(manager.surfaceRevision == revision)
        #expect(candidate.bounds?.min.x == -17)
        #expect(manager.commitPan(candidate))
        #expect(manager.surfaceRevision > revision)
        #expect(manager.visibleSurfaceGeometry.flatMap(\.positions).allSatisfy { $0.x >= -17.001 && $0.x <= 23.001 })
        #expect(!manager.commitPan(candidate))
    }

    @Test func anLODChangeRejectsTheWholePreparedPan() async throws {
        let manager = Tiles3DLODManager(provider: SurfaceFixtureProvider(), ecefConverter: .init(origin: center),
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let candidate = manager.preparePan(to: BoundaryPrism(boundary: boundary, scale: 1))
        manager.screenSpaceErrorThreshold = 0.01
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let current = manager.visibleSurfaceGeometry.map(\.positions)
        #expect(!manager.commitPan(candidate))
        #expect(manager.visibleSurfaceGeometry.map(\.positions) == current)
    }

    @Test func aPanPublishesOneCoherentVisibleSurfaceRevision() async throws {
        let manager = Tiles3DLODManager(provider: MultiSurfaceFixtureProvider(), ecefConverter: .init(origin: center),
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 0.01
        for _ in 0..<3 {
            _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        }
        #expect(manager.visibleSurfaceGeometry.count == 2)
        let moved = DioramaBoundary(vertices: boundary.vertices.map { $0 + SIMD2(3, 0) })
        let prism = BoundaryPrism(boundary: moved, scale: 1)
        var notifications = 0
        var observed: [TerrainSolidGenerator.Buffers] = []
        manager.onSurfaceInvalidated = { notifications += 1; observed = manager.visibleSurfaceGeometry }
        manager.setClipPrism(prism)
        #expect(notifications == 1)
        #expect(observed.count == 2)
        for part in observed {
            for point in part.positions {
                #expect(point.x >= -17.001 && point.x <= 23.001)
            }
        }
        #expect(observed.map(\.positions) == manager.visibleSurfaceGeometry.map(\.positions))
    }

    @Test func unclippedPanSnapshotMatchesRenderedShearedPlacement() async throws {
        let provider = SurfaceFixtureProvider(shear: true)
        let converter = ECEFConverter(origin: center)
        let manager = Tiles3DLODManager(provider: provider, ecefConverter: converter,
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        manager.setClipPrism(nil)
        let tile = try #require(root.children.compactMap { $0 as? ModelEntity }.first { $0.isEnabled })
        var transform = matrix_identity_double4x4
        transform.columns.1.x = 0.5
        let loader = Tile3DLoader(provider: provider, ecefConverter: converter, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), retainsSourceGeometry: true)
        let loaded = try #require(try await loader.loadTileFromData(SurfaceFixtureProvider.glb(height: 10), uri: "fixture", transform: transform))
        let source = try #require(loaded.source)
        let local = source.descriptors.flatMap { $0.positions.elements }
        let actual = try #require(manager.visibleSurfaceGeometry.first).positions
        #expect(actual.count == local.count)
        let rendered = tile.transform.matrix
        for (position, point) in zip(actual, local) {
            let expected = rendered * SIMD4<Float>(point, 1)
            #expect(simd_distance(position, SIMD3(expected.x, expected.y, expected.z)) < 1e-4)
        }
    }

    @Test func loaderSnapshotsUnclippedEntityPlacementExactly() async throws {
        let converter = ECEFConverter(origin: center)
        let loader = Tile3DLoader(provider: SurfaceFixtureProvider(), ecefConverter: converter)
        let loaded = try #require(try await loader.loadTileFromData(SurfaceFixtureProvider.glb(height: 12), uri: "fixture", transform: nil))
        #expect(loaded.surface.positions[0] == SIMD3<Float>(-50, 12, -50))
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [loaded.surface], scale: 0.5, datum: 10, pan: .init(1, 2))
        #expect(snapshot.surface.surfaceY(atX: -1, z: -2) == 1)
    }

    @Test func hiddenAncestorsWaitForVisibilityBeforeRecutting() async throws {
        let manager = Tiles3DLODManager(provider: SurfaceFixtureProvider(), ecefConverter: .init(origin: center),
            center: center, radiusMeters: 100, clipPrism: BoundaryPrism(boundary: boundary, scale: 1), panRange: 1)
        try await manager.start()
        let root = Entity()
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let parent = try #require(root.children.compactMap { $0 as? ModelEntity }.first)
        let mesh = try #require(parent.model?.mesh.lowLevelMesh)
        let initial = mesh.parts[0].bounds
        manager.screenSpaceErrorThreshold = 0.01
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        #expect(!parent.isEnabled)
        for x in [Float(3), 6] {
            let moved = DioramaBoundary(vertices: boundary.vertices.map { $0 + SIMD2(x, 0) })
            manager.setClipPrism(BoundaryPrism(boundary: moved, scale: 1))
        }
        #expect(mesh.parts[0].bounds == initial)
        manager.screenSpaceErrorThreshold = 1e12
        _ = await manager.update(parentEntity: root, cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        #expect(parent.isEnabled)
        let positions = try #require(manager.visibleSurfaceGeometry.first).positions
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0.x >= -14.001 && $0.x <= 26.001 && abs($0.y - 10) < 1e-4 })
        #expect(positions.contains { abs($0.x - 26) < 1e-4 })
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

    @Test func pendingPansNotifyOnlyWhenSurfaceAvailabilityChanges() async throws {
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 100,
            physicalSize: 40, boundary: boundary, style: .init(), panRange: 1)
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        await entity.waitForSurface()
        #expect(entity.surfaceSnapshot != nil)
        var notifications = 0
        entity.onSurfaceChange = { notifications += 1 }
        entity.setPanOffset(.init(1, 0))
        entity.setPanOffset(.init(2, 0))
        // Preparation leaves the old closed solid and query frame intact until atomic commit.
        #expect(entity.panOffset == .zero)
        await entity.waitForPanPresentation()
        #expect(notifications >= 1 && notifications <= 2)
        await entity.waitForSurface()
        #expect(entity.surfaceSnapshot != nil)
        #expect(notifications == 2)
    }

    @Test func committedPanCannotRestoreAnOldSurfaceSnapshot() async throws {
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 100,
            physicalSize: 40, boundary: boundary, style: .init(), panRange: 1)
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        // Stage before the first build finishes. After commit no answer from the old frame may return.
        entity.setPanOffset(.init(100, 0))
        await entity.waitForPanPresentation()
        if let snapshot = entity.surfaceSnapshot { #expect(snapshot.surface.surfaceY(atX: 0, z: 0) == nil) }
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

    @Test func shallowUndersideNeverBecomesItsOwnGroundDatum() async throws {
        let entity = try await Tiles3DEntity(provider: SurfaceFixtureProvider(), center: center, radiusMeters: 100,
            physicalSize: 400, boundary: boundary, style: .standard, panRange: 1)
        _ = await entity.updateLOD(cameraPosition: .init(0, 100, 100), screenHeight: 1000, fov: 1)
        let datum = try #require(entity.groundDatumElevation)
        let container = try #require(entity.children.first { $0.name == "Tiles3DTiles" })
        for offset in [SIMD2<Float>(0.01, 0), SIMD2(-0.01, 0), .zero] {
            entity.setPanOffset(offset)
            await entity.waitForPanPresentation()
            #expect(abs((entity.groundDatumElevation ?? -1000) - datum) < 1e-4)
            let visible = container.children.compactMap { $0 as? ModelEntity }.filter {
                $0.isEnabled && $0.name != "Tiles3DCutWall"
            }
            #expect(!visible.isEmpty)
            for tile in visible {
                let bottom = try #require(tile.children.first { $0.name == Tiles3DShallowUnderside.name } as? ModelEntity)
                #expect(bottom.model?.mesh === tile.model?.mesh)
                let delta = bottom.convert(position: .zero, to: container) - tile.convert(position: .zero, to: container)
                #expect(abs(delta.x) < 1e-4 && abs(delta.z) < 1e-4)
                #expect(abs(delta.y * 2 + 4) < 1e-4)
            }
            let base = try #require(entity.base)
            let bounds = base.visualBounds(relativeTo: entity)
            #expect(abs(bounds.min.y * 2 - Float(datum) * 2 + 4) < 1e-4)
        }
    }

}

private struct MultiSurfaceFixtureProvider: Tiles3DProvider {
    var attribution: String { "Coherent multi-tile fixture" }
    func fetchTileset() async throws -> Data {
        Data("""
        {"asset":{"version":"1.1"},"geometricError":10000,"root":{
          "boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},
          "geometricError":10000,"refine":"REPLACE","children":[
          {"boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},"geometricError":0,"content":{"uri":"a.glb"}},
          {"boundingVolume":{"region":[-0.001,-0.001,0.001,0.001,0,100]},"geometricError":0,"content":{"uri":"b.glb"}}]}}
        """.utf8)
    }
    func fetchTileContent(uri: String) async throws -> Data { SurfaceFixtureProvider.glb(height: uri == "a.glb" ? 10 : 20) }
}
