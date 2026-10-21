import Testing
@testable import Maquette

@Suite("Raster broad-phase ownership")
struct OverlaySpatialIndexTests {
    @Test func broadQueriesStayWithinOneVisitPerIndexedItem() throws {
        let bounds = (0..<400).map { item in
            let x = Double(item % 20), y = Double(item / 20)
            return OverlayBounds([SIMD2(x, y), SIMD2(x + 1.25, y + 1.25)])
        }
        var preparation = try OverlayWork(.init())
        let index = try OverlaySpatialIndex(bounds: bounds, work: &preparation)
        let query = OverlayBounds([SIMD2<Double>(3, 3), SIMD2<Double>(18, 18)])
        var work = try OverlayWork(.init(maxOperations: bounds.count))
        let candidates = try index.rasterCandidates(for: query, work: &work)
        let expected = Set(bounds.indices.filter { bounds[$0].intersects(query) })
        #expect(Set(candidates) == expected)
        #expect(candidates.count == expected.count)
        var insufficient = try OverlayWork(.init(maxOperations: bounds.count - 1))
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try index.rasterCandidates(for: query, work: &insufficient)
        }
    }

    @Test func rasterQueriesVisitEveryIntersectingItemExactlyOnce() throws {
        var bounds: [OverlayBounds] = []
        for item in 0..<100 {
            let x = Double(item % 10), y = Double(item / 10)
            bounds.append(OverlayBounds([SIMD2<Double>(x, y), SIMD2<Double>(x + 1.25, y + 1.25)]))
        }
        bounds.append(OverlayBounds([.init(-1, 4.5), .init(12, 4.5)]))
        bounds.append(OverlayBounds(point: .init(5, 5)))
        var preparation = try OverlayWork(.init())
        let index = try OverlaySpatialIndex(bounds: bounds, work: &preparation)
        let queries = (-1...12).flatMap { x in
            (-1...12).map { y in OverlayBounds([.init(Double(x), Double(y)), .init(Double(x) + 0.5, Double(y) + 0.5)]) }
        } + [OverlayBounds([.init(-10, -10), .init(20, 20)]), OverlayBounds(point: .init(5, 5))]
        for query in queries {
            var work = try OverlayWork(.init())
            let candidates = try index.rasterCandidates(for: query, work: &work)
            let expected = Set(bounds.indices.filter { bounds[$0].intersects(query) })
            #expect(Set(candidates) == expected)
            #expect(candidates.count == expected.count)
        }
    }
}
