import Foundation
import Testing
@testable import Maquette

@Suite("Polyline Mesh Generator Tests")
struct PolylineMeshGeneratorTests {
    @Test("Two-point polyline produces valid mesh")
    @MainActor
    func twoPointPolyline() throws {
        let points: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0)
        ]

        let mesh = try PolylineMeshGenerator.generateMesh(from: points, width: 0.01)
        #expect(mesh.contents.models.count > 0)
    }

    @Test("Degenerate input with fewer than 2 points throws error")
    @MainActor
    func degenerateInputThrows() {
        let singlePoint: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0)]

        #expect(throws: DioramaError.self) {
            _ = try PolylineMeshGenerator.generateMesh(from: singlePoint, width: 0.01)
        }

        let emptyPoints: [SIMD3<Float>] = []

        #expect(throws: DioramaError.self) {
            _ = try PolylineMeshGenerator.generateMesh(from: emptyPoints, width: 0.01)
        }
    }

    @Test("Multi-point polyline produces mesh with correct geometry")
    @MainActor
    func multiPointPolyline() throws {
        let points: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0.5, 0.1, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1.5, 0.05, 0.5)
        ]

        let mesh = try PolylineMeshGenerator.generateMesh(from: points, width: 0.005)
        #expect(mesh.contents.models.count > 0)
    }

    @Test("L-shaped polyline produces valid mesh")
    @MainActor
    func lShapedPolyline() throws {
        let points: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 0, 1)
        ]

        let mesh = try PolylineMeshGenerator.generateMesh(from: points, width: 0.01)
        #expect(mesh.contents.models.count > 0)
    }
}
