import RealityKit
import SwiftUI
import Testing
import simd
@testable import Maquette

@Suite("Visible photorealistic surface placement")
struct PhotorealisticSurfaceTests {
    private func triangle(_ y: Float, x: Float = 0) -> TerrainSolidGenerator.Buffers {
        .init(positions: [SIMD3(-1 + x, y, -1), SIMD3(1 + x, y, -1), SIMD3(x, y, 1)], indices: [0, 1, 2])
    }
    private let source = [OverlayTriangle(a: .init(point: .init(-1, -1), uv: .init(0, 0)),
        b: .init(point: .init(1, -1), uv: .init(1, 0)), c: .init(point: .init(0, 1), uv: .init(0.5, 1)))]

    @Test func topmostFaceIsIndependentOfWindingAndGapsStayAbsent() throws {
        var upper = triangle(3)
        upper.indices = [2, 1, 0]
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [triangle(1), upper], scale: 0.5, datum: 1, pan: .zero)
        #expect(snapshot.surface.surfaceY(atX: 0, z: 0) == 1)
        #expect(snapshot.surface.surfaceY(atX: 0.49, z: 0.49) == nil)
        #expect(snapshot.surface.surfaceY(atX: .nan, z: 0) == nil)
    }

    @Test func verticalFacadesOccludeButNeverInventHorizontalGround() throws {
        let wall = TerrainSolidGenerator.Buffers(positions: [SIMD3<Float>(0, 0, -1), .init(0, 2, -1), .init(0, 0, 1)], indices: [0, 1, 2])
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [wall], scale: 1, datum: 0, pan: .zero)
        #expect(snapshot.surface.isEmpty)
        #expect(snapshot.surface.surfaceY(atX: 0, z: 0) == nil)
        #expect(snapshot.occlusion.occludes(from: .init(-1, 0.5, 0), to: .init(1, 0.5, 0)))
    }

    @Test func drapingRemovesHiddenLowerAndCoplanarFragments() throws {
        for upper in [Float(1), 3] {
            let snapshot = try Tiles3DSurfaceSnapshot(geometry: [triangle(1), triangle(upper)], scale: 1, datum: 0, pan: .zero)
            let mesh = try snapshot.surface.drape(source, elevationToY: { $0 })
            #expect(mesh.positions.allSatisfy { abs($0.y - upper) < 0.00001 })
            #expect(abs(area(mesh) - 2) < 0.00001)
            #expect(mesh.uvs.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
    }

    @Test func crossingPlanesSplitAtTheirActualHeightIntersection() throws {
        var slope = triangle(0)
        slope.positions[0].y = -1; slope.positions[1].y = 1
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [triangle(0), slope], scale: 1, datum: 0, pan: .zero)
        let mesh = try snapshot.surface.drape(source, elevationToY: { $0 })
        #expect(abs(area(mesh) - 2) < 0.00001)
        #expect(mesh.positions.allSatisfy { abs($0.y - max(0, $0.x)) < 0.00001 })
        #expect(mesh.positions.contains { abs($0.x) < 0.00001 })
    }

    @Test func gapsClipAreaAndRelativeAndAbsoluteAltitudeRemainDistinct() throws {
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [triangle(2, x: 1)], scale: 1, datum: 0, pan: .zero)
        let ground = try snapshot.surface.drape(source, elevationToY: { $0 - 10 })
        #expect(area(ground) < 2 && area(ground) > 0)
        var elevated = source
        elevated[0].a.altitude = 4; elevated[0].b.altitude = 4; elevated[0].c.altitude = 4
        let relative = try snapshot.surface.drape(elevated, altitude: .relativeToGround, elevationToY: { $0 - 10 })
        #expect(relative.positions.allSatisfy { abs($0.y - 6) < 0.00001 })
        let absolute = try snapshot.surface.drape(elevated, altitude: .absolute, elevationToY: { $0 - 10 })
        #expect(abs(area(absolute) - 2) < 0.00001)
        #expect(absolute.positions.allSatisfy { abs($0.y + 6) < 0.00001 })
    }

    @Test func panScaleAndChangingDatumMatchRenderedTileTransform() throws {
        let initial = try Tiles3DSurfaceSnapshot(geometry: [triangle(12)], scale: 0.5, datum: 10, pan: .zero)
        let moved = try Tiles3DSurfaceSnapshot(geometry: [triangle(12)], scale: 0.5, datum: 11, pan: .init(0.2, -0.1))
        #expect(initial.surface.surfaceY(atX: 0, z: 0) == 1)
        #expect(moved.surface.surfaceY(atX: -0.2, z: 0.1) == 0.5)
        #expect(moved.buffers.positions[0] == .init(-0.7, 0.5, -0.4))
        // Immutable snapshots remain internally consistent rather than mutating an in-flight worker.
        #expect(initial.surface.surfaceY(atX: 0, z: 0) == 1)
    }

    @Test @MainActor func allContentKindsUseResidentMeshAndAbsentSurfaceIsHonest() async throws {
        let (_, rasterProxy) = try OverlayRenderFixture.make()
        var projection = EllipsoidProjection(center: rasterProxy.configuration.center, radiusMeters: 1000, physicalSize: 1)
        let ground = TerrainSolidGenerator.Buffers(positions: [SIMD3<Float>(-1, 0.3, -1), .init(1, 0.3, -1), .init(1, 0.3, 1), .init(-1, 0.3, 1)], indices: [0, 1, 2, 0, 2, 3])
        projection.surface = try OverlaySurfaceMesh(terrain: ground, resolvesOverlaps: true)
        let proxy = DioramaProxy(configuration: rasterProxy.configuration, projection: projection)
        #expect(proxy.canClampToSurface && proxy.canDrapeAreas)
        let center = Coordinate(proxy.configuration.center)
        let ring = LinearRing([Turf.destination(from: center, meters: 200, bearing: 225),
            Turf.destination(from: center, meters: 200, bearing: 315), Turf.destination(from: center, meters: 200, bearing: 45),
            Turf.destination(from: center, meters: 200, bearing: 135)])
        let bounds = try #require(GeographicBounds(enclosing: ring.coordinates))
        let root = DioramaEntity()
        let content = DioramaContentGroup {
            DioramaMarker("Pin", coordinate: center, id: "pin")
            DioramaPolyline(coordinates: ring.coordinates, id: "line")
            DioramaPolygon(Maquette.Polygon(exterior: ring), id: "polygon").fill(.green)
            DioramaCircle(center: center, radius: 200, id: "circle")
            DioramaImageOverlay(image: .init(id: "pixels", revision: "1", image: try! OverlayRenderFixture.image()), bounds: bounds, id: "image")
        }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(abs((root.markerEntities["pin"]?.position.y ?? 0) - 0.3) < 0.00001)
        #expect(root.overlayRenderer.records.count == 4)
        for record in root.overlayRenderer.records.values {
            #expect(!record.layers.isEmpty)
            #expect(record.layers.values.allSatisfy { $0.mesh.positions.allSatisfy { abs($0.y - 0.302) < 0.0003 } })
        }
        #expect(root.overlayRenderer.diagnostics.isEmpty)
        let annotation = DioramaAnnotation("Label", coordinate: center) { Text("Label") }
        #expect(try #require(DioramaAnnotationPlacement.position(for: annotation.annotation, projection: projection, configuration: proxy.configuration)).y > 0.3)
        projection.surface = nil
        let missing = DioramaProxy(configuration: proxy.configuration, projection: projection)
        #expect(!missing.canClampToSurface && !missing.canDrapeAreas)
        #expect(missing.position(for: center) == nil)
        #expect(DioramaAnnotationPlacement.position(for: annotation.annotation, projection: projection, configuration: proxy.configuration) == nil)
        root.applyContent(content, using: missing, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.markerEntities["pin"]?.isEnabled == false)
        #expect(root.overlayRenderer.diagnostics.count == 4)
        #expect(root.overlayRenderer.diagnostics.values.allSatisfy { $0 == .unsupportedSurface })
    }

    @Test @MainActor func pinIdentitySurvivesMissingSurfaceAndHiddenStyleChangesApplyOnReturn() async throws {
        let (_, raster) = try OverlayRenderFixture.make()
        var projection = EllipsoidProjection(center: raster.configuration.center, radiusMeters: 1000, physicalSize: 1)
        let ground = TerrainSolidGenerator.Buffers(positions: [SIMD3<Float>(-1, 0.3, -1), .init(1, 0.3, -1), .init(0, 0.3, 1)], indices: [0, 1, 2])
        let surface = try OverlaySurfaceMesh(terrain: ground, resolvesOverlaps: true)
        projection.surface = surface
        let root = DioramaEntity()
        func content(_ tint: Color) -> DioramaContentGroup {
            DioramaContentGroup { DioramaMarker("Pin", coordinate: Coordinate(raster.configuration.center), tint: tint, id: "pin") }
        }
        func apply(_ tint: Color) { root.applyContent(content(tint), using: .init(configuration: raster.configuration, projection: projection), physicalSize: 1) }
        apply(.orange)
        let original = try #require(root.markerEntities["pin"])
        projection.surface = nil
        apply(.orange)
        #expect(root.markerEntities["pin"] === original && !original.isEnabled)
        projection.surface = surface
        apply(.orange)
        #expect(root.markerEntities["pin"] === original && original.isEnabled)
        projection.surface = nil
        apply(.blue)
        #expect(root.markerEntities["pin"] === original && !original.isEnabled)
        projection.surface = surface
        apply(.blue)
        let restyled = try #require(root.markerEntities["pin"])
        #expect(restyled !== original && restyled.isEnabled)
        projection.surface = nil
        apply(.blue)
        root.applyContent(.empty, using: .init(configuration: raster.configuration, projection: projection), physicalSize: 1)
        #expect(root.markerEntities.isEmpty)
    }

    @Test func denseLocalDetailWithDistantGeometryFitsPhotorealisticWorkBudget() throws {
        // All detailed faces occupy less than one uniform bucket in the global bounds. A local
        // query must not re-examine every distant face for each fragment of a small overlay.
        var buffers = TerrainSolidGenerator.Buffers()
        let count = 35, size: Float = 0.01
        for x in 0..<count {
            for z in 0..<count {
                let a = Float(x) / Float(count) * size, b = Float(z) / Float(count) * size
                let c = Float(x + 1) / Float(count) * size, d = Float(z + 1) / Float(count) * size
                let base = UInt32(buffers.positions.count)
                buffers.positions += [.init(a, 0.2, b), .init(c, 0.2, b), .init(c, 0.2, d), .init(a, 0.2, d)]
                buffers.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        let base = UInt32(buffers.positions.count)
        buffers.positions += [.init(1, 0, 1), .init(2, 0, 1), .init(1, 0, 2)]
        buffers.indices += [base, base + 1, base + 2]
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [buffers], scale: 1, datum: 0, pan: .zero)
        let a = OverlayVertex(point: .init(0, 0)), b = OverlayVertex(point: .init(Double(size), 0))
        let c = OverlayVertex(point: .init(Double(size), Double(size))), d = OverlayVertex(point: .init(0, Double(size)))
        let mesh = try snapshot.surface.drape([.init(a: a, b: b, c: c), .init(a: a, b: c, c: d)], elevationToY: { $0 })
        #expect(abs(area(mesh) - Double(size * size)) < 1e-9)
        #expect(mesh.positions.allSatisfy { abs($0.y - 0.2) < 0.00001 })
    }

    @Test func capturedSubpixelFragmentRetainsFiniteUnitNormal() throws {
        // Float normal normalization underflows for this finite clipped fragment. Only the
        // three synthetic vertex values are retained from the failing calculation.
        let positions: [SIMD3<Float>] = [.init(0.0064316522, 0.06294676, 0.00054017897),
            .init(0.0064316527, 0.06294676, 0.00054017856), .init(0.0064316527, 0.06294676, 0.0005401786)]
        let surface = try OverlaySurfaceMesh(terrain: .init(positions: positions, indices: [0, 1, 2]), resolvesOverlaps: true)
        let vertices = positions.map { OverlayVertex(point: .init(Double($0.x), Double($0.z))) }
        let mesh = try surface.drape([.init(a: vertices[0], b: vertices[1], c: vertices[2])], elevationToY: { $0 })
        #expect(!mesh.indices.isEmpty)
        #expect(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0) - 1) < 0.00001 })
        #expect(mesh.positions.allSatisfy { abs($0.y - 0.06294676) < 0.000001 })
    }

    @Test func triangleBVHNeverDropsExactIntersectionsIncludingThinBoundaryCrossings() throws {
        var triangles: [OverlayTriangle] = []
        for x in 0..<20 {
            for z in 0..<20 {
                let a = SIMD2(Double(x) / 10 - 1, Double(z) / 10 - 1)
                let b = a + SIMD2(0.1, 0), c = a + SIMD2(0.1, 0.1), d = a + SIMD2(0, 0.1)
                triangles += [.init(a: .init(point: a), b: .init(point: b), c: .init(point: c)),
                    .init(a: .init(point: a), b: .init(point: c), c: .init(point: d))]
            }
        }
        var work = try OverlayWork(.init(maxOperations: 50_000_000))
        let index = try OverlaySurfaceIndex(bounds: triangles.map(\.bounds), hierarchical: true, work: &work)
        let queries: [[SIMD2<Double>]] = [
            [.init(-1, -1), .init(1, 1), .init(1.000001, 1)],
            [.init(-1.000001, -1), .init(1, 1), .init(-1, -1)],
            [.init(-1.1, 0), .init(1.1, 0), .init(0, 0.000001)],
            [.init(-0.3, -0.4), .init(0.7, -0.4), .init(0.2, 0.9)]
        ]
        for query in queries {
            let source = OverlayTriangle(a: .init(point: query[0]), b: .init(point: query[1]), c: .init(point: query[2]))
            let candidates = Set(try index.candidates(for: source, work: &work))
            for (id, triangle) in triangles.enumerated() {
                let exact = try OverlayAreaGeometry.intersect(source, with: triangle.vertices.map(\.point), epsilon: 1e-12, work: &work)
                if abs(OverlayMath.area(exact)) > 1e-20 { #expect(candidates.contains(id)) }
            }
            if query == queries[0] { #expect(candidates.count < triangles.count / 2) }
        }
    }

    @Test func nearlyVerticalNumericalSliversAreNotHeightPlanesButStillOcclude() throws {
        let wall = TerrainSolidGenerator.Buffers(positions: [SIMD3<Float>(0, 0, -1), .init(0.0000001, 2, -1), .init(0, 0, 1)], indices: [0, 1, 2])
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [wall], scale: 1, datum: 0, pan: .zero)
        #expect(snapshot.surface.isEmpty)
        #expect(snapshot.occlusion.occludes(from: .init(-1, 0.5, 0), to: .init(1, 0.5, 0)))
    }

    @Test func disjointRoofMasksDoNotRepeatedlyPartitionUnrelatedGroundFragments() throws {
        var buffers = triangle(0)
        for x in 0..<4 {
            for z in 0..<4 {
                let center = SIMD2<Float>(-0.3 + Float(x) * 0.2, -0.6 + Float(z) * 0.15)
                let base = UInt32(buffers.positions.count)
                buffers.positions += [.init(center.x - 0.02, 1, center.y - 0.02),
                    .init(center.x + 0.02, 1, center.y - 0.02), .init(center.x, 1, center.y + 0.02)]
                buffers.indices += [base, base + 1, base + 2]
            }
        }
        let snapshot = try Tiles3DSurfaceSnapshot(geometry: [buffers], scale: 1, datum: 0, pan: .zero)
        let mesh = try snapshot.surface.drape(source, elevationToY: { $0 })
        #expect(abs(area(mesh) - 2) < 0.00001)
        #expect(mesh.indices.count / 3 < 320)
        #expect(mesh.positions.allSatisfy { abs($0.y) < 0.00001 || abs($0.y - 1) < 0.00001 })
    }

    private func area(_ mesh: OverlayMesh) -> Double {
        stride(from: 0, to: mesh.indices.count, by: 3).reduce(0) { sum, i in
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[i + $0])] }
            return sum + Double(abs((p[1].x - p[0].x) * (p[2].z - p[0].z) - (p[1].z - p[0].z) * (p[2].x - p[0].x))) / 2
        }
    }
}
