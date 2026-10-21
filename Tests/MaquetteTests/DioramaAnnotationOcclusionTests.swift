import Testing
@testable import Maquette

@Suite("Annotation terrain occlusion")
struct DioramaAnnotationOcclusionTests {
    private let wall: [SIMD3<Float>] = [
        [-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]
    ]

    @Test("A terrain ridge hides a label across it but leaves raised sight lines clear")
    func ridge() {
        let mesh = DioramaAnnotationOcclusionIndex(
            positions: [[-1, 0, -1], [1, 0, -1], [0, 1, 0], [-1, 0, 1], [1, 0, 1]],
            indices: [0, 1, 2, 3, 2, 4]
        )
        #expect(mesh.occludes(from: [0, 0.5, -2], to: [0, 0.5, 2]))
        #expect(!mesh.occludes(from: [0, 1.5, -2], to: [0, 1.5, 2]))
    }

    @Test("Vertical cut walls occlude from either side and winding")
    func wallIntersections() {
        let mesh = DioramaAnnotationOcclusionIndex(positions: wall, indices: [0, 1, 2, 0, 2, 3])
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 1]))
        #expect(mesh.occludes(from: [0, 0, 1], to: [0, 0, -1]))
        #expect(!mesh.occludes(from: [2, 0, -1], to: [2, 0, 1]))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, -0.5]))
        #expect(!mesh.occludes(from: [-2, 0, 0.5], to: [2, 0, 0.5]))
    }

    @Test("The endpoint tolerance excludes the label's own supporting surface")
    func endpointTolerance() {
        let mesh = DioramaAnnotationOcclusionIndex(positions: wall, indices: [0, 1, 2, 0, 2, 3])
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 0]))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 0.00005]))
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 0.001]))
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 0.00005], tolerance: 0.00001))
        #expect(!mesh.occludes(from: [0, 0, 0], to: [0, 0, 1]))
    }

    @Test("Malformed and degenerate triangles are skipped without losing valid neighbors")
    func invalidTriangles() {
        let positions = wall + [[.nan, 0, 0], [.infinity, 0, 0]]
        let mesh = DioramaAnnotationOcclusionIndex(
            positions: positions,
            indices: [0, 0, 0, 0, 4, 1, 0, 5, 1, 0, 999, 1, 0, 1, 2, 3]
        )
        #expect(mesh.occludes(from: [0.5, 0, -1], to: [0.5, 0, 1]))
        #expect(!mesh.occludes(from: [.nan, 0, -1], to: [0, 0, 1]))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [.infinity, 0, 1]))
        #expect(!mesh.occludes(from: [0, 0, 1], to: [0, 0, 1]))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], tolerance: .nan))
        let empty = DioramaAnnotationOcclusionIndex(positions: [], indices: [0, 1, 2])
        #expect(!empty.occludes(from: [0, 0, -1], to: [0, 0, 1]))
    }

    @Test("Dynamic height queries follow moving terrain without rebuilding the fixed topology")
    func dynamicHeights() {
        let mesh = DioramaAnnotationOcclusionIndex(
            positions: wall, indices: [0, 1, 2, 0, 2, 3], dynamicHeights: true
        )
        let raised = wall.map { $0 + SIMD3<Float>(0, 5, 0) }
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: wall))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: raised))
        // This sight line lies entirely above the index's initial vertical bounds.
        #expect(mesh.occludes(from: [0, 5, -1], to: [0, 5, 1], positions: raised))
        #expect(!mesh.occludes(from: [0, 5, -1], to: [0, 5, 1], positions: wall))
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 1]))
    }

    @Test("A wall initially collapsed by heights can become an occluder after a pan")
    func initiallyDegenerateDynamicWall() {
        let flattened = wall.map { SIMD3<Float>($0.x, 0, $0.z) }
        let mesh = DioramaAnnotationOcclusionIndex(
            positions: flattened, indices: [0, 1, 2, 0, 2, 3], dynamicHeights: true
        )
        #expect(!mesh.occludes(from: [0, 0.5, -1], to: [0, 0.5, 1], positions: flattened))
        #expect(mesh.occludes(from: [0, 0.5, -1], to: [0, 0.5, 1], positions: wall))
    }

    @Test("Dynamic current positions reject invalid vertices and short buffers safely")
    func invalidDynamicPositions() {
        let mesh = DioramaAnnotationOcclusionIndex(
            positions: wall, indices: [0, 1, 2, 0, 2, 3], dynamicHeights: true
        )
        var invalid = wall
        invalid[0].y = .nan
        invalid[2].y = .infinity
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: invalid))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: []))
        #expect(!mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: Array(wall.prefix(2))))
        #expect(mesh.occludes(from: [0, 0, -1], to: [0, 0, 1], positions: wall))
    }

    @Test("BVH traversal finds exact triangles beyond multiple branches")
    func hierarchy() {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for value in 0..<128 {
            let x = Float(value * 3)
            let start = UInt32(positions.count)
            positions += [[x - 1, -1, 0], [x + 1, -1, 0], [x, 1, 0]]
            indices += [start, start + 1, start + 2]
        }
        let mesh = DioramaAnnotationOcclusionIndex(positions: positions, indices: indices)
        let dynamic = DioramaAnnotationOcclusionIndex(positions: positions, indices: indices, dynamicHeights: true)
        let raised = positions.map { $0 + SIMD3<Float>(0, 10, 0) }
        for value in [0, 31, 64, 127] {
            let x = Float(value * 3)
            #expect(mesh.occludes(from: [x, 0, -1], to: [x, 0, 1]))
            #expect(!mesh.occludes(from: [x + 1.4, 0, -1], to: [x + 1.4, 0, 1]))
            #expect(dynamic.occludes(from: [x, 10, -1], to: [x, 10, 1], positions: raised))
            #expect(!dynamic.occludes(from: [x, 0, -1], to: [x, 0, 1], positions: raised))
        }
    }
}
