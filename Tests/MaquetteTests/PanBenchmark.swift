import Foundation
import RealityKit
import Testing
import simd
@testable import Maquette

private extension Duration {
    var elapsedMilliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// Opt-in measurement harness for diagnosing pan cost. Not a correctness test.
/// Run with `MAQUETTE_RUN_PAN_BENCHMARK=1 swift test -c release --filter PanBenchmark`.
@Suite("Pan Benchmark", .enabled(
    if: ProcessInfo.processInfo.environment["MAQUETTE_RUN_PAN_BENCHMARK"] == "1",
    "Diagnostic only; set MAQUETTE_RUN_PAN_BENCHMARK=1 and build in release mode"
))
struct PanBenchmark {
    private func heightField() -> TerrainHeightField {
        let size = 256
        var values = [Float]()
        values.reserveCapacity(size * size)
        for row in 0..<size {
            for col in 0..<size {
                values.append(Float((row * 31 + col * 17) % 800))
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: size, height: size, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(repeating: 1.44),
            elevationScale: 0.0001
        )
    }

    @Test("Measure resample and LowLevelMesh buffer updates")
    @MainActor
    func measurePanCost() throws {
        let field = heightField()
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8))

        var geometry = TerrainSolidGenerator.buildGeometry(
            heightField: field,
            boundary: boundary,
            baseDepth: 0.12,
            includesWalls: true,
            includesBottom: true,
            resolution: 256
        )

        let vertices = geometry.top.positions.count + geometry.walls.positions.count
        let clock = ContinuousClock()

        // Fail rather than reporting a zero update cost when graphics resources are unavailable.
        let surfaceMesh = try ChunkSurfaceMesh(buffers: geometry.top, name: "bench")
        let wallMesh = try ChunkSurfaceMesh(buffers: geometry.walls, name: "benchWalls")
        var resampleTotal = Duration.zero
        var updateTotal = Duration.zero
        for step in 1...10 {
            let offset = SIMD2<Float>(Float(step) * 0.005, 0)
            resampleTotal += clock.measure {
                TerrainSolidGenerator.resample(&geometry, heightField: field, panOffset: offset)
            }
            updateTotal += clock.measure {
                surfaceMesh.update(from: geometry.top)
                wallMesh.update(from: geometry.walls)
            }
        }

        print("""

        ===== PAN COST =====
        vertices:  \(vertices) (top \(geometry.top.positions.count), walls \(geometry.walls.positions.count))
        resample:  \(resampleTotal.elapsedMilliseconds / 10) ms/frame
        buffers:   \(updateTotal.elapsedMilliseconds / 10) ms/frame
        total:     \((resampleTotal.elapsedMilliseconds + updateTotal.elapsedMilliseconds) / 10) ms/frame
        ====================

        """)
    }
}
