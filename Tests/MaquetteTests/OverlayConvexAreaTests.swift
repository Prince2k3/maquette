import simd
import Testing
@testable import Maquette

@Suite("Convex overlay partitions")
struct OverlayConvexAreaTests {
    @Test(arguments: [false, true])
    func denseInteriorFitsConstantWorkBudget(inHole: Bool) throws {
        func ring(_ radius: Double) -> [OverlayVertex] {
            (0..<300).map { i in
                let angle = Double(i) / 300 * 2 * Double.pi
                return .init(point: SIMD2(cos(angle), sin(angle)) * radius)
            }
        }
        let convex = try #require(OverlayConvexArea(inHole ? [ring(2), ring(1)] : [ring(1)]))
        let triangle = OverlayTriangle(a: .init(point: .init(0.60, 0.60)),
            b: .init(point: .init(0.65, 0.60)), c: .init(point: .init(0.60, 0.65)))
        var work = try OverlayWork(.init(maxOperations: 2))
        switch try convex.intersection(of: triangle, epsilon: 1e-10, work: &work) {
        case .whole: #expect(!inHole)
        case .empty: #expect(inHole)
        case .clipped: Issue.record("Interior face unexpectedly fragmented")
        }
    }

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
    @Test(arguments: [false, true])
    func denseConvexBoundaryFitsLocalWorkBudget(reverse: Bool) throws {
        var ring = (0..<300).map { i in
            let angle = Double(i) / 300 * 2 * Double.pi
            return OverlayVertex(point: .init(cos(angle), sin(angle)), uv: .init(0.2, 0.8), altitude: 7)
        }
        if reverse { ring.reverse() }
        let triangle = OverlayTriangle(a: .init(point: .init(0.98, -0.01), uv: .init(0.2, 0.8), altitude: 7),
            b: .init(point: .init(1.02, -0.01), uv: .init(0.2, 0.8), altitude: 7),
            c: .init(point: .init(0.99, 0.02), uv: .init(0.2, 0.8), altitude: 7))
        var referenceWork = try OverlayWork(.init())
        let reference = try OverlayAreaGeometry.intersect(triangle.vertices, with: ring.map(\.point), epsilon: 1e-10, work: &referenceWork)
        var work = try OverlayWork(.init(maxOperations: 240))
        let convex = try #require(OverlayConvexArea([ring]))
        let fragments = try convex.fragments(of: triangle, epsilon: 1e-10, work: &work)
        #expect(abs(fragments.reduce(0) { $0 + abs(OverlayMath.area($1)) } - abs(OverlayMath.area(reference))) < 1e-12)
        #expect(fragments.flatMap { $0 }.allSatisfy { $0.uv == SIMD2<Double>(0.2, 0.8) && $0.altitude == 7 })
    }

    @Test(arguments: [false, true], [SIMD2<Double>.zero, SIMD2<Double>(1e6, -1e6)])
    func hierarchyMatchesIndependentConvexCuts(reverse: Bool, offset: SIMD2<Double>) throws {
        func ring(_ count: Int, radius: Double, center: SIMD2<Double>) -> [OverlayVertex] {
            var values = (0..<count).map { i in
                let angle = Double(i) / Double(count) * 2 * Double.pi
                return OverlayVertex(point: offset + center + SIMD2(cos(angle), sin(angle)) * radius,
                                     uv: .init(0.2, 0.8), altitude: 7)
            }
            if reverse { values.reverse() }
            return values
        }
        let exterior = ring(300, radius: 1, center: .zero)
        let holes = [ring(100, radius: 0.2, center: .init(0.2, 0)), ring(37, radius: 0.1, center: .init(-0.4, -0.2))]
        let convex = try #require(OverlayConvexArea([exterior] + holes))
        for x in [-1.1, -0.7, -0.3, 0, 0.3, 0.7, 1.1] {
            for z in [-1.1, -0.7, -0.3, 0, 0.3, 0.7, 1.1] {
                for size in [0.03, 0.4, 2.6] {
                    func v(_ x: Double, _ z: Double) -> OverlayVertex {
                        .init(point: offset + SIMD2(x, z), uv: .init(0.2, 0.8), altitude: 7)
                    }
                    let triangle = OverlayTriangle(a: v(x, z), b: v(x + size, z + size * 0.1), c: v(x + size * 0.2, z + size))
                    var referenceWork = try OverlayWork(.init())
                    func cutArea(_ ring: [OverlayVertex]) throws -> Double {
                        abs(OverlayMath.area(try OverlayAreaGeometry.intersect(triangle.vertices, with: ring.map(\.point), epsilon: 1e-10, work: &referenceWork)))
                    }
                    let expected = try cutArea(exterior) - holes.reduce(0) { try $0 + cutArea($1) }
                    var work = try OverlayWork(.init())
                    let actual = try convex.fragments(of: triangle, epsilon: 1e-10, work: &work)
                    let area = actual.reduce(0) { $0 + abs(OverlayMath.area($1)) }
                    #expect(abs(area - expected) < max(1e-10, abs(offset.x) * Double.ulpOfOne * 64))
                    #expect(actual.flatMap { $0 }.allSatisfy { $0.isFinite && $0.uv == SIMD2<Double>(0.2, 0.8) && $0.altitude == 7 })
                }
            }
        }
    }

    @Test(arguments: [false, true], [SIMD2<Double>.zero, SIMD2<Double>(1e6, -1e6)])
    func regionalClassificationRetainsExactCutsAndRejectsOutOfRegionReuse(reverse: Bool, offset: SIMD2<Double>) throws {
        func ring(_ radius: Double) -> [OverlayVertex] {
            var values = (0..<100).map { i in
                let angle = Double(i) / 100 * 2 * Double.pi
                return OverlayVertex(point: offset + SIMD2(cos(angle), sin(angle)) * radius)
            }
            if reverse { values.reverse() }
            return values
        }
        let convex = try #require(OverlayConvexArea([ring(1), ring(0.3)]))
        var work = try OverlayWork(.init())
        let region = try convex.region(for: .init([offset + SIMD2(-0.8, -0.8), offset + SIMD2(0.8, 0.8)]),
            epsilon: 1e-10, work: &work)
        for x in [-1.1, -0.5, 0, 0.3, 0.7, 1.1] {
            for y in [-0.7, -0.2, 0.2, 0.7] {
                let triangle = OverlayTriangle(a: .init(point: offset + SIMD2(x, y)),
                    b: .init(point: offset + SIMD2(x + 0.1, y)), c: .init(point: offset + SIMD2(x, y + 0.1)))
                func fragments(_ result: OverlayConvexArea.Intersection) -> [[OverlayVertex]] {
                    switch result { case .empty: []; case .whole: [triangle.vertices]; case .clipped(let values): values }
                }
                let reference = try convex.fragments(of: triangle, epsilon: 1e-10, work: &work)
                let actual = fragments(try convex.intersection(of: triangle, region: region, epsilon: 1e-10, work: &work))
                #expect(actual == reference)
            }
        }
    }

    @Test func regionalHoleRetainsBoundaryTouchingPlanes() throws {
        func ring(_ low: Double, _ high: Double) -> [OverlayVertex] {
            [SIMD2(low, low), .init(high, low), .init(high, high), .init(low, high)].map { .init(point: $0) }
        }
        let convex = try #require(OverlayConvexArea([ring(-2, 2), ring(0, 1)]))
        var work = try OverlayWork(.init())
        let region = try convex.region(for: .init([.zero, .init(1, 1)]), epsilon: 1e-10, work: &work)
        let vertex = OverlayVertex(point: .zero)
        let triangle = OverlayTriangle(a: vertex, b: vertex, c: vertex)
        switch try convex.intersection(of: triangle, region: region, epsilon: 1e-10, work: &work) {
        case .whole: break
        default: Issue.record("Hole boundary must retain the original outside-first zero predicate")
        }
    }

    @Test func planeIntervalsEncloseCancellationInOffsetProducts() throws {
        let plane = OverlayConvexArea.Plane(origin: .init(95856862.10775836, 87389920.29767154),
            normal: .init(-10701943.973862514, 11738822.55863355))
        let tree = try #require(OverlayConvexArea.PlaneTree(Array(repeating: plane, count: 32),
            bounds: .init([.init(-1e8, -1e8), .init(1e8, 1e8)])))
        let vertex = OverlayVertex(point: .init(-6.0949603336608725e-9, 6.0949603336608725e-9))
        let interval = try #require(tree.interval(tree.nodes[0], box: .init(point: vertex.point), epsilon: 1e-12))
        let side = plane.side(vertex)
        #expect(interval.x <= side && interval.y >= side)
    }

}
