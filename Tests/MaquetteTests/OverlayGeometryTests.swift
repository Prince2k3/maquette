import Foundation
import simd
import Testing
@testable import Maquette

enum OverlayFixture {
    static func ring(_ points: [SIMD2<Double>]) -> [OverlayVertex] {
        points.map { OverlayVertex(point: $0, uv: $0 / 4, altitude: $0.x + 2 * $0.y) }
    }
    static let square = ring([.init(0, 0), .init(4, 0), .init(4, 4), .init(0, 4)])
    static let uShape = ring([.init(0, 0), .init(4, 0), .init(4, 4), .init(3, 4),
                              .init(3, 1), .init(1, 1), .init(1, 4), .init(0, 4)])
    static func area(_ triangles: [OverlayTriangle]) -> Double {
        triangles.reduce(0) { $0 + abs(cross($1.b.point - $1.a.point, $1.c.point - $1.a.point)) / 2 }
    }
    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
}

@Suite("Overlay polygon geometry")
struct OverlayPolygonGeometryTests {
    @Test func holesPreserveAreaInBothWindings() throws {
        let holes = [OverlayFixture.ring([.init(1, 1), .init(2, 1), .init(2, 2), .init(1, 2)]),
                     OverlayFixture.ring([.init(2.5, 1), .init(3.5, 1), .init(3.5, 3), .init(2.5, 3)])]
        for reverse in [false, true] {
            let rings = ([OverlayFixture.square] + holes).map { reverse ? Array($0.reversed()) : $0 }
            let triangles = try OverlayPolygonTessellator.triangulate(rings: rings)
            #expect(abs(OverlayFixture.area(triangles) - 13) < 1e-9)
            for triangle in triangles {
                #expect(OverlayFixture.cross(triangle.b.point - triangle.a.point, triangle.c.point - triangle.a.point) < 0)
                let center = (triangle.a.point + triangle.b.point + triangle.c.point) / 3
                #expect(!(center.x > 1 && center.x < 2 && center.y > 1 && center.y < 2))
                #expect(!(center.x > 2.5 && center.x < 3.5 && center.y > 1 && center.y < 3))
            }
        }
    }

    @Test func concaveAreaDoesNotFillTheNotch() throws {
        let triangles = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.uShape])
        #expect(abs(OverlayFixture.area(triangles) - 10) < 1e-9)
    }

    @Test func clippingRetainsTwoDisconnectedIslandsWithoutBridging() throws {
        let strip = OverlayFixture.ring([.init(-1, 2), .init(5, 2), .init(5, 3), .init(-1, 3)])
        let source = try OverlayPolygonTessellator.triangulate(rings: [strip])
        let clipped = try OverlayAreaGeometry.clip(source, boundary: OverlayFixture.uShape)
        #expect(abs(OverlayFixture.area(clipped) - 2) < 1e-9)
        #expect(clipped.allSatisfy { triangle in
            let xs = [triangle.a.point.x, triangle.b.point.x, triangle.c.point.x]
            return xs.allSatisfy { $0 <= 1 + 1e-9 } || xs.allSatisfy { $0 >= 3 - 1e-9 }
        })
    }

    @Test func duplicateClosingVerticesNormalizeButInvalidRingsFail() throws {
        let repeated = OverlayFixture.square + [OverlayFixture.square[0], OverlayFixture.square[0]]
        #expect(abs(OverlayFixture.area(try OverlayPolygonTessellator.triangulate(rings: [repeated])) - 16) < 1e-9)
        let crossed = OverlayFixture.ring([.init(0, 0), .init(2, 2), .init(0, 2), .init(2, 0)])
        #expect(throws: OverlayGeometryError.selfIntersection) { try OverlayPolygonTessellator.triangulate(rings: [crossed]) }
        let outside = OverlayFixture.ring([.init(5, 5), .init(6, 5), .init(5, 6)])
        #expect(throws: OverlayGeometryError.invalidHole) {
            try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square, outside])
        }
        let nan = OverlayFixture.ring([.init(.nan, 0), .init(1, 0), .init(0, 1)])
        #expect(throws: OverlayGeometryError.nonFiniteInput) { try OverlayPolygonTessellator.triangulate(rings: [nan]) }
    }

    @Test func touchingOverlappingAndNestedHolesAreRejected() {
        let hole = OverlayFixture.ring([.init(1, 1), .init(3, 1), .init(3, 3), .init(1, 3)])
        let nested = OverlayFixture.ring([.init(1.5, 1.5), .init(2, 1.5), .init(1.5, 2)])
        let touching = OverlayFixture.ring([.init(0, 1), .init(1, 1), .init(1, 2)])
        for rings in [[OverlayFixture.square, hole, nested], [OverlayFixture.square, touching],
                      [OverlayFixture.square, hole, hole]] {
            #expect(throws: OverlayGeometryError.invalidHole) { try OverlayPolygonTessellator.triangulate(rings: rings) }
        }
    }

    @Test func budgetsThrowInsteadOfReturningPartialArea() {
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square], limits: .init(maxTriangles: 1))
        }
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square], limits: .init(maxOperations: 1))
        }
    }

    @Test func sampleCoverageHasNeitherOverlapsNorFilledHoles() throws {
        let hole = OverlayFixture.ring([.init(1, 1), .init(3, 1), .init(3, 3), .init(1, 3)])
        let triangles = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square, hole])
        for x in 0..<19 {
            for z in 0..<19 {
                let p = SIMD2(Double(x) * 0.21 + 0.031, Double(z) * 0.21 + 0.057)
                let hits = triangles.filter { triangle in
                    let sides = [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)]
                        .map { OverlayFixture.cross($0.1.point - $0.0.point, p - $0.0.point) }
                    return sides.allSatisfy { $0 <= 0 }
                }.count
                #expect(hits == ((p.x > 1 && p.x < 3 && p.y > 1 && p.y < 3) ? 0 : 1))
            }
        }
    }

    @Test func smallPolygonsAndTranslatedPolygonsPreserveArea() throws {
        for (offset, scale) in [(0.0, 1e-6), (1e8, 1.0)] {
            let ring = OverlayFixture.square.map { OverlayVertex(point: $0.point * scale + SIMD2(repeating: offset)) }
            let triangles = try OverlayPolygonTessellator.triangulate(rings: [ring])
            #expect(abs(OverlayFixture.area(triangles) - 16 * scale * scale) < 1e-20 + 1e-9 * scale * scale)
        }
    }

    @Test func adjacentRepresentableXCoordinatesDoNotLoseAnEntireSlab() throws {
        let x = 1e16
        let ring = OverlayFixture.ring([.init(x, 0), .init(x + 2, 0), .init(x + 2, 4), .init(x, 4)])
        let triangles = try OverlayPolygonTessellator.triangulate(rings: [ring])
        #expect(abs(OverlayFixture.area(triangles) - 8) < 1e-9)
    }
}

@Suite("Overlay line geometry")
struct OverlayLineGeometryTests {
    @Test func outsideEndpointsStillProduceTheCrossing() throws {
        let runs = try OverlayLineClipper.clip(OverlayFixture.ring([.init(-1, 2), .init(5, 2)]), boundary: OverlayFixture.square)
        #expect(runs.count == 1)
        #expect(runs.first?.first?.vertex.point == SIMD2(0, 2))
        #expect(runs.first?.last?.vertex.point == SIMD2(4, 2))
        #expect(runs.first?.first?.distance == 1)
        #expect(runs.first?.last?.distance == 5)
    }

    @Test func reentrySplitsRunsAndPreservesSourceDistanceAndAttributes() throws {
        let runs = try OverlayLineClipper.clip(OverlayFixture.ring([.init(-1, 2), .init(5, 2)]), boundary: OverlayFixture.uShape)
        #expect(runs.count == 2)
        #expect(runs[0].last?.distance == 2)
        #expect(runs[1].first?.distance == 4)
        #expect(runs[1].first?.vertex.altitude == 7)
        #expect(runs[1].first?.vertex.uv == SIMD2(0.75, 0.5))
    }

    @Test func boundaryOverlapIsRetainedAndTangencyDoesNotCreateARun() throws {
        let along = try OverlayLineClipper.clip(OverlayFixture.ring([.init(-1, 0), .init(5, 0)]), boundary: OverlayFixture.square)
        #expect(along.count == 1)
        let tangent = try OverlayLineClipper.clip(OverlayFixture.ring([.init(-1, 1), .init(1, -1)]), boundary: OverlayFixture.square)
        #expect(tangent.isEmpty)
    }

    @Test func fullyInsidePolylineKeepsItsCorners() throws {
        let path = OverlayFixture.ring([.init(1, 1), .init(1, 1), .init(2, 1), .init(2, 3)])
        let runs = try OverlayLineClipper.clip(path, boundary: OverlayFixture.square)
        #expect(runs.count == 1)
        #expect(runs[0].map(\.vertex.point) == [SIMD2(1, 1), SIMD2(2, 1), SIMD2(2, 3)])
        #expect(runs[0].last?.distance == 3)
    }

    @Test func expandedStrokeCannotEscapeTheBoundary() throws {
        let line = OverlayFixture.ring([.init(-1, 0.1), .init(5, 0.1)])
        let triangles = try OverlayStrokeGeometry.build(line, width: 1, boundary: OverlayFixture.square)
        #expect(abs(OverlayFixture.area(triangles) - 2.4) < 1e-9)
        #expect(triangles.flatMap { [$0.a, $0.b, $0.c] }.allSatisfy { $0.point.x >= -1e-9 && $0.point.x <= 4 + 1e-9 && $0.point.y >= -1e-9 })
    }

    @Test func outsideCenterlineCanStillContributeItsWideFootprint() throws {
        let triangles = try OverlayStrokeGeometry.build(OverlayFixture.ring([.init(-1, -0.1), .init(5, -0.1)]), width: 0.4,
                                                        boundary: OverlayFixture.square)
        #expect(abs(OverlayFixture.area(triangles) - 0.4) < 1e-9)
    }

    @Test func lineOutputBudgetBoundsFragmentCount() {
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try OverlayLineClipper.clip(OverlayFixture.ring([.init(-1, 2), .init(5, 2)]), boundary: OverlayFixture.uShape,
                                        limits: .init(maxTriangles: 1))
        }
    }

    @Test func aReversingPathStillProducesAFiniteClippedFootprint() throws {
        let triangles = try OverlayStrokeGeometry.build(OverlayFixture.ring([.init(1, 2), .init(3, 2), .init(1, 2)]),
                                                        width: 1, boundary: OverlayFixture.square)
        #expect(!triangles.isEmpty)
        #expect(triangles.flatMap(\.vertices).allSatisfy { $0.isFinite && (1.5...2.5).contains($0.point.y) })
    }

    @Test func interpolationDoesNotOverflowFiniteOppositeAttributes() throws {
        let path = [OverlayVertex(point: .init(-1, 2), uv: .init(repeating: -1e308), altitude: -1e308),
                    OverlayVertex(point: .init(5, 2), uv: .init(repeating: 1e308), altitude: 1e308)]
        let runs = try OverlayLineClipper.clip(path, boundary: OverlayFixture.square)
        #expect(runs.flatMap { $0 }.allSatisfy { $0.vertex.isFinite })
    }
}
