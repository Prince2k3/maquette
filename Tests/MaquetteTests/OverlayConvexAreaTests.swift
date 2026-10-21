import simd
import Testing
@testable import Maquette

@Suite("Convex overlay partitions")
struct OverlayConvexAreaTests {
    @Test(arguments: [false, true])
    func holeSplitClassifiesEachVertexOnce(reverse: Bool) throws {
        func ring(_ radius: Double) -> [OverlayVertex] {
            let points: [SIMD2<Double>] = [.init(-radius, -radius), .init(radius, -radius),
                                         .init(radius, radius), .init(-radius, radius)]
            return (reverse ? points.reversed() : points).map { .init(point: $0, uv: .init(0.2, 0.8), altitude: 7) }
        }
        let convex = try #require(OverlayConvexArea([ring(3), ring(0.25)]))
        let triangle = OverlayTriangle(a: .init(point: .init(-2, -2), uv: .init(0.2, 0.8), altitude: 7),
            b: .init(point: .init(2, -2), uv: .init(0.2, 0.8), altitude: 7),
            c: .init(point: .init(0, 2), uv: .init(0.2, 0.8), altitude: 7))
        var work = try OverlayWork(.init(maxOperations: 30))
        let fragments = try convex.fragments(of: triangle, epsilon: 1e-10, work: &work)
        #expect(abs(fragments.reduce(0) { $0 + abs(OverlayMath.area($1)) } - 7.75) < 1e-8)
        for vertex in fragments.flatMap({ $0 }) {
            #expect(vertex.uv == SIMD2<Double>(0.2, 0.8))
            #expect(vertex.altitude == 7)
        }
    }
}
