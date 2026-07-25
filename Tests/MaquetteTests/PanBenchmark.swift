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

/// Temporary measurement harness for diagnosing pan cost. Not a correctness test.
@Suite("Pan Benchmark", .disabled("Diagnostic only. Run with: swift test -c release --filter PanBenchmark"))
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

    @Test("Measure resample and mesh rebuild")
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

        var resampleTotal = Duration.zero
        for step in 1...10 {
            let offset = SIMD2<Float>(Float(step) * 0.005, 0)
            resampleTotal += clock.measure {
                TerrainSolidGenerator.resample(&geometry, heightField: field, panOffset: offset)
            }
        }

        var rebuildTotal = Duration.zero
        if let surfaceMesh = try? ChunkSurfaceMesh(buffers: geometry.top, name: "bench"),
           let wallMesh = try? ChunkSurfaceMesh(buffers: geometry.walls, name: "benchWalls") {
            for _ in 1...10 {
                rebuildTotal += clock.measure {
                    surfaceMesh.update(from: geometry.top)
                    wallMesh.update(from: geometry.walls)
                }
            }
        } else {
            print("!! ChunkSurfaceMesh unavailable in this context")
        }

        print("""

        ===== PAN COST =====
        vertices:  \(vertices) (top \(geometry.top.positions.count), walls \(geometry.walls.positions.count))
        resample:  \(resampleTotal.elapsedMilliseconds / 10) ms/frame
        rebuild:   \(rebuildTotal.elapsedMilliseconds / 10) ms/frame
        total:     \((resampleTotal.elapsedMilliseconds + rebuildTotal.elapsedMilliseconds) / 10) ms/frame
        ====================

        """)
    }
}
