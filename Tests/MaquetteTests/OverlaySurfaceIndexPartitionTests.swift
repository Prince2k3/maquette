import Testing
import simd
@testable import Maquette

@Suite("Photogrammetry index partitions")
struct OverlaySurfaceIndexPartitionTests {
    @Test(arguments: [0, 1, 2])
    func partitionsPreserveExactCandidates(distribution: Int) throws {
        let bounds = (0..<8192).map { index -> OverlayBounds in
            switch distribution {
            case 0:
                let point = SIMD2(Double(index % 32) - 16, Double((index / 32) % 32) - 16)
                return OverlayBounds([point, point + SIMD2(0.25, 0.5)])
            case 1:
                // More than 32 levels of clustered coordinates exercise the bounded-depth
                // median fallback, with many repeated centers and inclusive shared edges.
                let x = Double(sign: .plus, exponent: -(index % 80), significand: 1)
                return OverlayBounds([SIMD2(x, 0), SIMD2(x + 1e-18, 1e-18)])
            default:
                return OverlayBounds([SIMD2(-0.5, -0.5), SIMD2(0.5, 0.5)])
            }
        }
        var work = try OverlayWork(.init(maxOperations: 100_000_000))
        let index = try OverlaySurfaceIndex(bounds: bounds, hierarchical: true, work: &work)
        for origin in [SIMD2<Double>(-16, -16), .zero, SIMD2(0.25, 0.5), SIMD2(0.5, 0.5),
            SIMD2(1e-16, 0), SIMD2(1e-9, 0), SIMD2(8, -3), SIMD2(30, 30)] {
            let query = OverlayBounds([origin, origin + SIMD2(1e-18, 0.25)])
            #expect(try index.candidates(for: query, work: &work) == bounds.indices.filter { bounds[$0].intersects(query) })
        }
    }

    @Test func indexConstructionRemainsBudgeted() throws {
        let bounds = (0..<1024).map { OverlayBounds(point: SIMD2(Double($0), 0)) }
        var work = try OverlayWork(.init(maxOperations: 100))
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            _ = try OverlaySurfaceIndex(bounds: bounds, hierarchical: true, work: &work)
        }
    }
}
