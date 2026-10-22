import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Photorealistic pan build budget", .serialized, .enabled(
    if: ProcessInfo.processInfo.environment["MAQUETTE_RUN_PHOTO_BENCHMARK"] == "1",
    "Opt in on a quiet machine in Release; this is a diagnostic frame-budget gate"
))
struct PhotorealPanBenchmark {
    @Test func denseQueryIndexFitsAFrame() throws {
        let bounds = (0..<100_000).map { index in
            let x = Double((index * 179) % 997) / 1000, z = Double((index * 61) % 991) / 1000
            return OverlayBounds([SIMD2(x, z), SIMD2(x + 0.003, z + 0.004)])
        }
        var times: [Double] = []
        for _ in 0..<5 {
            var work = try OverlayWork(.init(maxOperations: 100_000_000))
            let start = ContinuousClock.now
            let index = try OverlaySurfaceIndex(bounds: bounds, hierarchical: true, work: &work)
            let duration = ContinuousClock.now - start
            times.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            let query = OverlayBounds([SIMD2(0.45, 0.45), SIMD2(0.46, 0.46)])
            let actual = try index.candidates(for: query, work: &work)
            #expect(actual == bounds.indices.filter { bounds[$0].intersects(query) })
        }
        let median = times.sorted()[times.count / 2]
        print("PHOTO INDEX 100000 bounds medianMs=\(median) samples=\(times)")
        #expect(median < 16)
    }
    @Test func denseWallBuildFitsAFrame() async throws {
        let prism = BoundaryPrism(boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), scale: 1)
        var edges: [Tiles3DCutEdge] = []
        for edge in 0..<prism.boundary.edgeCount {
            let (a, b) = prism.boundary.edge(edge)
            for segment in 0..<20 {
                let left = a + (b - a) * (Float(segment) / 20)
                let right = a + (b - a) * (Float(segment + 1) / 20)
                for layer in 0..<4 {
                    let y = Float(0.3) + Float(layer) * 0.003 + Float(segment % 3) * 0.001
                    edges.append(.init(a: SIMD3(left.x, y, left.y), b: SIMD3(right.x, y + 0.001, right.y), boundaryEdge: edge))
                }
            }
        }
        var times: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let mesh = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
                earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
            let duration = ContinuousClock.now - start
            times.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            #expect(mesh.parts.count == 2 && !mesh.mesh.indices.isEmpty)
        }
        let median = times.sorted()[times.count / 2]
        print("PHOTO WALL \(edges.count) cuts medianMs=\(median) samples=\(times)")
        #expect(median < 8)
        // Keep the other half-frame for clipping and scene publication.
        var parallelTimes: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let mesh = try #require(try await Tiles3DShallowClosure.buildParallel(edges: edges, lowestY: 0, prism: prism,
                earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
            let duration = ContinuousClock.now - start
            parallelTimes.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            #expect(mesh.parts.count == 2 && !mesh.mesh.indices.isEmpty)
        }
        let parallelMedian = parallelTimes.sorted()[parallelTimes.count / 2]
        print("PHOTO PARALLEL WALL \(edges.count) cuts medianMs=\(parallelMedian) samples=\(parallelTimes)")
        #expect(parallelMedian < 8)
    }

}
