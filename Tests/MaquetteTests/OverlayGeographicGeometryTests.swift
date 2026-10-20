import Foundation
import simd
import Testing
@testable import Maquette

@Suite("Overlay geographic geometry")
struct OverlayGeographicGeometryTests {
    private struct LinearProjection: DioramaProjection {
        var panOffset: SIMD2<Float> = .zero
        func point(for coordinate: Coordinate) -> SIMD2<Float> { SIMD2(Float(coordinate.longitude), -Float(coordinate.latitude)) - panOffset }
        func surfaceY(atX x: Float, z: Float) -> Float? { 0 }
        func y(forElevation meters: Double) -> Float { Float(meters) }
    }

    @Test func antimeridianProjectionUsesTheSameLocalWorldCopy() throws {
        let geometry = try OverlayGeographicGeometry(projection: LinearProjection(), referenceLongitude: 180, domain: .mercator)
        let path = try geometry.project([.init(latitude: 0, longitude: 179), .init(latitude: 0, longitude: -179)])
        #expect(path.map(\.point.x) == [179, 181])
    }

    @Test func offscreenDatelineGeometryDoesNotCrossTheOppositeSideOfTheWorld() throws {
        let geometry = try OverlayGeographicGeometry(projection: LinearProjection(), referenceLongitude: 0, domain: .mercator)
        let path = try geometry.project([.init(latitude: 0, longitude: 179), .init(latitude: 0, longitude: -179)])
        #expect(abs(path[1].point.x - path[0].point.x) == 2)
        let circle = try geometry.circle(center: .init(latitude: 0, longitude: 180), radius: 1000, maximumError: 0.001)
        let xs = circle.map(\.point.x)
        #expect(try #require(xs.max()) - #require(xs.min()) < 0.1)
    }

    @Test func mercatorDomainRejectsPolesAndNonfiniteCoordinates() throws {
        let geometry = try OverlayGeographicGeometry(projection: LinearProjection(), referenceLongitude: 0, domain: .mercator)
        #expect(throws: OverlayGeometryError.invalidProjection) { try geometry.project([.init(latitude: 90, longitude: 0)]) }
        #expect(throws: OverlayGeometryError.nonFiniteInput) { try geometry.project([.init(latitude: 0, longitude: .nan)]) }
    }

    @Test func rasterAdapterUsesTheAnchorsUnwrappedWorldCopyAndPan() throws {
        let center = Coordinate(latitude: 0, longitude: 180.1)
        let anchor = TerrainAnchor(centeredOn: center, zoom: 0, extent: .init(4, 4), radiusMeters: 1000)
        let field = TerrainHeightField(grids: [ElevationGrid(width: 2, height: 2, values: [0, 0, 0, 0])],
            tilePositions: [(x: 1, y: 0)], anchor: anchor, elevationScale: 1)
        let projection = TerrainProjection(heightField: field, panOffset: .init(0.25, 0.1))
        let geometry = try OverlayGeographicGeometry(projection: projection)
        let point = try #require(geometry.project([.init(latitude: 0, longitude: -179.9)]).first)
        #expect(abs(point.point.x + 0.25) < 1e-6)
        #expect(abs(point.point.y + 0.1) < 1e-6)
    }

    @Test func circlesUseGeographicMetersAndRefineWithinProjectedError() throws {
        let geometry = try OverlayGeographicGeometry(projection: LinearProjection(), referenceLongitude: 0, domain: .mercator)
        let center = Coordinate(latitude: 0, longitude: 0)
        let ring = try geometry.circle(center: center, radius: 1000, maximumError: 0.0001)
        #expect(ring.count > 8 && ring.count <= 2048)
        for vertex in ring {
            let coordinate = Coordinate(latitude: -vertex.point.y, longitude: vertex.point.x)
            #expect(abs(Turf.distance(from: center, to: coordinate) - 1000) < 0.01)
        }
        for i in ring.indices {
            let chordMiddle = (ring[i].point + ring[(i + 1) % ring.count].point) / 2
            let radiusDegrees = 1000 / Turf.earthRadiusMeters * 180 / .pi
            #expect(abs(simd_length(chordMiddle) - radiusDegrees) <= 0.000101)
        }
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try geometry.circle(center: center, radius: 1000, maximumError: 1e-12, limits: .init(maxCircleSegments: 8))
        }
        #expect(throws: OverlayGeometryError.invalidRadius) { try geometry.circle(center: center, radius: -1, maximumError: 0.1) }
    }

    @Test func imageUVsStayAnchoredToOriginalWrappedExtentAfterClipping() throws {
        let geometry = try OverlayGeographicGeometry(projection: LinearProjection(), referenceLongitude: 180, domain: .mercator)
        let image = try geometry.image(bounds: .init(west: 179, south: -1, east: -179, north: 1))
        let mask = OverlayFixture.ring([.init(180, -1), .init(181, -1), .init(181, 1), .init(180, 1)])
        let triangles = try OverlayAreaGeometry.clip(try OverlayPolygonTessellator.triangulate(rings: [image]), boundary: mask)
        #expect(abs(OverlayFixture.area(triangles) - 2) < 1e-8)
        for vertex in triangles.flatMap(\.vertices) {
            #expect(abs(vertex.uv.x - (vertex.point.x - 179) / 2) < 1e-6)
            #expect(abs(vertex.uv.y - (vertex.point.y + 1) / 2) < 1e-6)
        }
    }
}
