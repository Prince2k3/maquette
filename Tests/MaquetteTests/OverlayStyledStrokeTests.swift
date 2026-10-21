import simd
import Testing
@testable import Maquette

@Suite("Styled overlay strokes")
struct OverlayStyledStrokeTests {
    private let boundary = OverlayFixture.ring([.init(-10, -10), .init(10, -10), .init(10, 10), .init(-10, 10)])
    private func stroke(_ points: [SIMD2<Double>], _ style: DioramaStrokeStyle, closed: Bool = false,
                        constantAttributes: Bool = false) throws -> [OverlayTriangle] {
        let path = constantAttributes ? points.map { OverlayVertex(point: $0) } : OverlayFixture.ring(points)
        var distance = [0.0]
        for i in 1..<points.count { distance.append(distance[i - 1] + simd_distance(points[i - 1], points[i])) }
        return try OverlayStyledStroke.build(path, widths: points.map { _ in 2 }, distances: distance,
                                             style: style, closed: closed, boundary: boundary)
    }
    @Test func capsAndJoinsHavePredictableAreaWithoutDoubleCoverage() throws {
        let path: [SIMD2<Double>] = [.init(0, 0), .init(4, 0)]
        let butt = try stroke(path, .init(width: .physicalMeters(2)))
        let square = try stroke(path, .init(width: .physicalMeters(2), lineCap: .square))
        let round = try stroke(path, .init(width: .physicalMeters(2), lineCap: .round))
        #expect(abs(OverlayFixture.area(butt) - 8) < 1e-8)
        #expect(abs(OverlayFixture.area(square) - 12) < 1e-8)
        #expect(abs(OverlayFixture.area(round) - (8 + .pi)) < 0.02)
        let bent = try stroke([.init(0, 0), .init(4, 0), .init(4, 4)], .init(width: .physicalMeters(2), lineJoin: .miter))
        #expect(abs(OverlayFixture.area(bent) - 16) < 1e-8)
    }
    @Test func dashesKeepTheirPhaseOutsideTheChunkAndInvalidPatternsFail() throws {
        let path = OverlayFixture.ring([.init(-5, 0), .init(5, 0)])
        let result = try OverlayStyledStroke.build(path, widths: [1, 1], distances: [0, 10],
            style: .init(width: .physicalMeters(1), dash: [2, 2]), boundary: boundary)
        #expect(abs(OverlayFixture.area(result) - 6) < 1e-8)
        let small = OverlayFixture.ring([.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)])
        let clipped = try OverlayStyledStroke.build(path, widths: [1, 1], distances: [0, 10],
            style: .init(width: .physicalMeters(1), dash: [2, 2]), boundary: small)
        #expect(abs(OverlayFixture.area(clipped) - 2) < 1e-8)
        #expect(throws: OverlayGeometryError.self) {
            try OverlayStyledStroke.build(path, widths: [1, 1], distances: [0, 10],
                style: .init(dash: [0, 2]), boundary: boundary)
        }
    }
    @Test func closedOutlinesDoNotAcquireEndCapsOrFillTheirInterior() throws {
        let result = try stroke([.init(0, 0), .init(4, 0), .init(4, 4), .init(0, 4), .init(0, 0)],
                                .init(width: .physicalMeters(2), lineCap: .square), closed: true)
        #expect(abs(OverlayFixture.area(result) - 32) < 1e-7)
    }
    @Test(arguments: [false, true])
    func tenThousandPointSmoothPathFitsDefaultBudgets(rotated: Bool) throws {
        let points = (0..<10_000).map { index in
            let x = Double(index) / 9_999 * 0.8 - 0.4
            let point = SIMD2(x, sin(x * 12) * 0.15)
            return rotated ? SIMD2(point.y, -point.x) : point
        }
        let vertices = points.map { OverlayVertex(point: $0) }
        var distances = [0.0]
        for index in 1..<points.count {
            distances.append(distances[index - 1] + simd_distance(points[index - 1], points[index]))
        }
        let result = try OverlayStyledStroke.build(vertices, widths: points.map { _ in 0.001 },
            distances: distances, style: .init(width: .physicalMeters(0.001)), boundary: boundary)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.vertices.allSatisfy(\.isFinite) })
        // A thin, non-self-crossing smooth stroke has area width * arc length. Shared joins
        // must retain this footprint without overlapping translucent triangles.
        #expect(abs(OverlayFixture.area(result) - distances.last! * 0.001) < 0.000001)
    }

    @Test func crossingAndLimitedMiterPathsKeepUnionCoverage() throws {
        let crossing = try stroke([.init(-2, -2), .init(2, 2), .init(-2, 2), .init(2, -2)],
                                  .init(width: .physicalMeters(2), lineJoin: .miter), constantAttributes: true)
        #expect(crossing.allSatisfy { $0.vertices.allSatisfy(\.isFinite) })
        // The crossing at the center is unioned once, including for translucent strokes.
        let center = SIMD2<Double>(0.123, 0.041)
        let coveredArea = crossing.filter { triangle in
            let p = triangle.vertices.map(\.point)
            return abs(OverlayMath.cross(p[1] - p[0], center - p[0])) > 1e-12
                && OverlayMath.locate(center, in: triangle.vertices, epsilon: 1e-12) == .inside
        }
        #expect(coveredArea.count == 1)
        let limited = try stroke([.init(0, 0), .init(4, 0), .init(4, 4)],
                                 .init(width: .physicalMeters(2), lineJoin: .miter, miterLimit: 1), constantAttributes: true)
        #expect(abs(OverlayFixture.area(limited) - 15.5) < 1e-8)
    }

    @Test(arguments: [false, true], 0..<3)
    func sharedMiterRibbonMatchesGeneralUnion(squareCaps: Bool, shape: Int) throws {
        let paths: [[SIMD2<Double>]] = [
            [.init(0, 0), .init(4, 0)],
            [.init(0, 0), .init(4, 0), .init(4, 4)],
            // A 53-degree interior corner, with long enough adjacent segments for its miter.
            [.init(0, 0), .init(5, 0), .init(2, 4)]
        ]
        let points = paths[shape]
        var distances = [0.0]
        for i in 1..<points.count { distances.append(distances[i - 1] + simd_distance(points[i - 1], points[i])) }
        let style = DioramaStrokeStyle(width: .physicalMeters(2), lineCap: squareCaps ? .square : .butt,
                                       lineJoin: .miter)
        func build(varyingUVs: Bool) throws -> [OverlayTriangle] {
            let vertices = points.enumerated().map { index, point in
                OverlayVertex(point: point, uv: varyingUVs ? SIMD2(Double(index), Double(index) / 2) : .zero,
                              altitude: 7)
            }
            return try OverlayStyledStroke.build(vertices, widths: points.map { _ in 2 }, distances: distances,
                                                 style: style, boundary: boundary)
        }
        let shared = try build(varyingUVs: false)
        // Vary only attributes: geometry stays identical while the general patch union is used.
        let general = try build(varyingUVs: true)
        let expected = distances.last! * 2 + (squareCaps ? 4 : 0)
        #expect(abs(OverlayFixture.area(shared) - expected) < 1e-8)
        #expect(abs(OverlayFixture.area(general) - expected) < 1e-8)
        #expect(shared.allSatisfy { $0.vertices.allSatisfy { $0.uv == .zero && abs($0.altitude - 7) < 1e-10 } })
        var work = try OverlayWork(.init())
        func overlap(_ a: OverlayTriangle, _ b: OverlayTriangle, work: inout OverlayWork) throws -> Double {
            let polygon = try OverlayAreaGeometry.intersect(a, with: b.vertices.map(\.point), epsilon: 1e-12, work: &work)
            return abs(OverlayMath.area(polygon))
        }
        // Equal area alone could miss displaced geometry. Their intersection must cover both
        // complete footprints, and shared-ribbon triangles must not cover one another.
        var commonArea = 0.0
        for a in shared {
            for b in general { commonArea += try overlap(a, b, work: &work) }
        }
        #expect(abs(commonArea - expected) < 1e-8)
        for i in shared.indices {
            for j in shared.indices where j > i {
                #expect(try overlap(shared[i], shared[j], work: &work) < 1e-10)
            }
        }
    }

    @Test func varyingAttributesSurviveGeneralUnionAndBoundaryClipping() throws {
        let vertices = [
            OverlayVertex(point: .init(-5, 0), uv: .init(0, 0), altitude: 10),
            OverlayVertex(point: .init(5, 0), uv: .init(1, 2), altitude: 30)
        ]
        let clip = OverlayFixture.ring([.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)])
        let result = try OverlayStyledStroke.build(vertices, widths: [1, 1], distances: [0, 10],
            style: .init(width: .physicalMeters(1)), boundary: clip)
        #expect(abs(OverlayFixture.area(result) - 2) < 1e-10)
        for vertex in result.flatMap(\.vertices) {
            let fraction = (vertex.point.x + 5) / 10
            #expect(abs(vertex.uv.x - fraction) < 1e-10)
            #expect(abs(vertex.uv.y - fraction * 2) < 1e-10)
            #expect(abs(vertex.altitude - (10 + fraction * 20)) < 1e-10)
            #expect(vertex.point.x >= -1 - 1e-10 && vertex.point.x <= 1 + 1e-10)
        }
        #expect(result.flatMap(\.vertices).contains { abs($0.point.x + 1) < 1e-10 })
        #expect(result.flatMap(\.vertices).contains { abs($0.point.x - 1) < 1e-10 })
    }

}
