import Foundation
import RealityKit
import Testing
import simd
@testable import Maquette

/// The GPU clip has to agree with `Tiles3DClipper`, which is the definition of the algorithm and
/// the fallback the kernel hands work back to. Nothing else in the suite can check that: the kernel
/// is written in a different language, compiled at runtime, and its output ordering is decided by
/// the hardware, so a divergence would otherwise only show up as geometry going subtly wrong on a
/// device.
///
/// Ordering is exactly why these compare aggregates rather than buffers. Threads reserve their
/// output with an atomic, so triangles land in whatever order the GPU produced them — which is fine
/// for a mesh, and means the honest comparison is over quantities that do not depend on order:
/// how many triangles, how much surface, and how far the geometry reaches.
///
/// Degenerate triangles are counted separately for a measured reason. Clipping a lattice to a
/// 128-sided outline, the two sides disagreed on 2 triangles out of 876 — every one of them under
/// 1e-10 in area, a sliver whose corner sits on a half-plane where the GPU's fused multiply-add and
/// the CPU's separate multiply and subtract land on opposite signs. Above that threshold the counts
/// were identical at every scale tried, and the total areas agreed to nine significant figures. So
/// the assertion is on the geometry that draws something; a raw count would fail on arithmetic that
/// is not wrong in either place.
@Suite("3D Tiles GPU Clipper Tests")
@MainActor
struct Tiles3DGPUClipperTests {
    // MARK: - Agreement With the CPU Clip

    @Test("The kernel compiles and cuts a circular outline the way the CPU clip does")
    func matchesCPUOnACircle() throws {
        guard let gpu = Tiles3DGPUClipper() else { return }
        try compare(gpu: gpu, prism: Self.circle(radius: 1, sides: 128), geometry: Self.lattice())
    }

    @Test("The kernel agrees with the CPU clip on a square outline")
    func matchesCPUOnASquare() throws {
        // A four-sided outline puts most of the work on the exact clip rather than on the two
        // circles, and its corners are where a triangle meets two half-planes at once.
        guard let gpu = Tiles3DGPUClipper() else { return }
        let square = BoundaryPrism(
            boundary: DioramaBoundary(vertices: [
                SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1),
            ]),
            scale: 1
        )
        try compare(gpu: gpu, prism: square, geometry: Self.lattice())
    }

    @Test("The kernel agrees with the CPU clip on a concave outline")
    func matchesCPUOnAConcaveOutline() throws {
        // A concave outline is split into several convex pieces, so a triangle can be clipped more
        // than once and the interior splits must not be mistaken for cuts along the boundary.
        guard let gpu = Tiles3DGPUClipper() else { return }
        let ell = BoundaryPrism(
            boundary: DioramaBoundary(vertices: [
                SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 0), SIMD2(0, 0), SIMD2(0, 1), SIMD2(-1, 1),
            ]),
            scale: 1
        )
        try compare(gpu: gpu, prism: ell, geometry: Self.lattice())
    }

    @Test("A tile wholly inside the outline survives whole and reports no cut")
    func interiorTileIsUntouched() throws {
        guard let gpu = Tiles3DGPUClipper() else { return }
        let geometry = Self.lattice(extent: 0.3, step: 0.05)
        let result = try clip(gpu: gpu, geometry: geometry, to: Self.circle(radius: 1, sides: 128))
        #expect(result.triangleCount == Self.triangleCount(of: geometry))
        #expect(result.cutEdgeCount == 0)
    }

    @Test("A tile wholly outside the outline comes back empty")
    func exteriorTileIsDropped() throws {
        guard let gpu = Tiles3DGPUClipper() else { return }
        var geometry = Self.lattice(extent: 0.3, step: 0.1)
        geometry = Self.translated(geometry, by: SIMD3(20, 0, 20))
        let result = try clip(gpu: gpu, geometry: geometry, to: Self.circle(radius: 1, sides: 128))
        #expect(result.triangleCount == 0)
    }

    @Test("Vertical geometry survives the cut")
    func verticalGeometrySurvives() throws {
        // The clip runs in three dimensions against vertical planes precisely so building facades
        // are not collapsed to a line and deleted. A wall standing across the outline is the case
        // that would catch a kernel that projected onto the horizontal plane first.
        guard let gpu = Tiles3DGPUClipper() else { return }
        var descriptor = MeshDescriptor(name: "wall")
        descriptor.positions = MeshBuffers.Positions([
            SIMD3(-2, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 50, 0), SIMD3(-2, 50, 0),
        ])
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3(0, 0, 1), count: 4))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(
            Array(repeating: SIMD2<Float>.zero, count: 4)
        )
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])

        let geometry = Tiles3DSourceGeometry(
            descriptors: [descriptor],
            placement: matrix_identity_float4x4,
            material: SimpleMaterial()
        )
        let result = try clip(gpu: gpu, geometry: geometry, to: Self.circle(radius: 1, sides: 128))
        #expect(result.triangleCount > 0)
        // Full height kept, horizontal extent cut back to the outline.
        #expect(result.bounds.max.y > 49)
        #expect(result.bounds.max.x <= 1.001)
        #expect(result.bounds.min.x >= -1.001)
    }

    // MARK: - Comparison

    private struct Summary {
        var triangleCount = 0
        /// Triangles big enough to draw something — see the note on the suite.
        var drawnTriangleCount = 0
        var area: Double = 0
        var cutEdgeCount = 0
        var bounds = BoundingBox(min: .zero, max: .zero)
    }

    /// Below this a triangle covers no pixel at any zoom and is only an artefact of where the cut
    /// happened to fall.
    private static let degenerateArea = 1e-10

    private func compare(
        gpu: Tiles3DGPUClipper,
        prism: BoundaryPrism,
        geometry: Tiles3DSourceGeometry
    ) throws {
        let onGPU = try clip(gpu: gpu, geometry: geometry, to: prism)
        let cpu = Tiles3DClipper.clip(
            descriptors: geometry.descriptors,
            placement: geometry.placement,
            to: prism
        )
        let cpuAreas = Self.areas(vertices: cpu.vertices, indices: cpu.indices)
        let onCPU = Summary(
            triangleCount: cpuAreas.count,
            drawnTriangleCount: cpuAreas.count { $0 > Self.degenerateArea },
            area: cpuAreas.reduce(0, +),
            cutEdgeCount: cpu.cutEdges.count,
            bounds: cpu.bounds
        )

        #expect(onGPU.drawnTriangleCount == onCPU.drawnTriangleCount)
        #expect(onGPU.cutEdgeCount == onCPU.cutEdgeCount)
        // Surface area is the test that catches an inexact clip. Two clips can agree on triangle
        // counts while disagreeing about where the cut fell, and area is what notices.
        #expect(abs(onGPU.area - onCPU.area) <= onCPU.area * 1e-4)
        #expect(simd_distance(onGPU.bounds.min, onCPU.bounds.min) < 1e-3)
        #expect(simd_distance(onGPU.bounds.max, onCPU.bounds.max) < 1e-3)
    }

    /// Runs one tile through the kernel and summarises what came back.
    private func clip(
        gpu: Tiles3DGPUClipper,
        geometry: Tiles3DSourceGeometry,
        to prism: BoundaryPrism
    ) throws -> Summary {
        var summary = Summary()
        var resolved = false
        gpu.clip([(uri: "test", source: geometry)], to: prism) { _, outcome in
            switch outcome {
            case .clipped(let vertices, let indices, let cutEdges, let bounds):
                resolved = true
                let areas = Self.areas(vertices: vertices, indices: indices)
                summary.triangleCount = areas.count
                summary.drawnTriangleCount = areas.count { $0 > Self.degenerateArea }
                summary.area = areas.reduce(0, +)
                summary.cutEdgeCount = cutEdges.count
                summary.bounds = bounds
            case .empty:
                resolved = true
            case .unresolved:
                resolved = false
            }
        }
        // Falling back is legitimate at runtime but not here — these tiles are well inside what a
        // thread's polygon can hold, so a fallback means the kernel failed rather than declined.
        #expect(resolved)
        return summary
    }

    // MARK: - Support

    private static func circle(radius: Float, sides: Int) -> BoundaryPrism {
        let vertices = (0..<sides).map { index -> SIMD2<Float> in
            let angle = Float(index) / Float(sides) * 2 * .pi
            return SIMD2(cos(angle) * radius, sin(angle) * radius)
        }
        return BoundaryPrism(boundary: DioramaBoundary(vertices: vertices), scale: 1)
    }

    /// A rolling lattice of triangles, wide enough that the outline crosses well inside it.
    ///
    /// Heights, normals and texture coordinates all vary across it, so anything the clip
    /// interpolates has a gradient to get wrong.
    private static func lattice(extent: Float = 2, step: Float = 0.1) -> Tiles3DSourceGeometry {
        let side = Int((extent * 2 / step).rounded()) + 1
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(side * side)

        for row in 0..<side {
            for column in 0..<side {
                let x = -extent + Float(column) * step
                let z = -extent + Float(row) * step
                let y = sin(x * 3) * cos(z * 2) * 0.4
                positions.append(SIMD3(x, y, z))
                normals.append(simd_normalize(SIMD3(x * 0.1, 1, z * 0.1)))
                uvs.append(SIMD2(Float(column) / Float(side - 1), Float(row) / Float(side - 1)))
            }
        }

        var indices: [UInt32] = []
        for row in 0..<(side - 1) {
            for column in 0..<(side - 1) {
                let a = UInt32(row * side + column)
                let b = a + 1
                let c = UInt32((row + 1) * side + column)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        var descriptor = MeshDescriptor(name: "lattice")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return Tiles3DSourceGeometry(
            descriptors: [descriptor],
            placement: matrix_identity_float4x4,
            material: SimpleMaterial()
        )
    }

    private static func translated(
        _ geometry: Tiles3DSourceGeometry,
        by offset: SIMD3<Float>
    ) -> Tiles3DSourceGeometry {
        var placement = matrix_identity_float4x4
        placement.columns.3 = SIMD4(offset.x, offset.y, offset.z, 1)
        return Tiles3DSourceGeometry(
            descriptors: geometry.descriptors,
            placement: placement,
            material: geometry.material
        )
    }

    private static func triangleCount(of geometry: Tiles3DSourceGeometry) -> Int {
        geometry.descriptors.reduce(0) { total, descriptor in
            guard case .triangles(let indices) = descriptor.primitives else { return total }
            return total + indices.count / 3
        }
    }

    private static func areas<V: Collection, I: Collection>(
        vertices: V,
        indices: I
    ) -> [Double] where V.Element == Tiles3DVertex, I.Element == UInt32,
                        V.Index == Int, I.Index == Int {
        var areas: [Double] = []
        areas.reserveCapacity(indices.count / 3)
        var index = indices.startIndex
        while index + 2 < indices.endIndex {
            let a = vertices[Int(indices[index])].position
            let b = vertices[Int(indices[index + 1])].position
            let c = vertices[Int(indices[index + 2])].position
            areas.append(Double(simd_length(simd_cross(b - a, c - a))) / 2)
            index += 3
        }
        return areas
    }
}
