import simd
import Testing
@testable import Maquette

@Suite("Styled overlay strokes")
struct OverlayStyledStrokeTests {
    private let boundary = OverlayFixture.ring([.init(-10, -10), .init(10, -10), .init(10, 10), .init(-10, 10)])
    private func stroke(_ points: [SIMD2<Double>], _ style: DioramaStrokeStyle, closed: Bool = false) throws -> [OverlayTriangle] {
        let path = OverlayFixture.ring(points)
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
}
