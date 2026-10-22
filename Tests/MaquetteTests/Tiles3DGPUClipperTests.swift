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

    @Test("Panned circles, hexagons and squares agree with the fixed-footprint CPU clip")
    func builtInFootprintsStayExactThroughPanRecuts() throws {
        let gpu = try #require(Tiles3DGPUClipper())
        for shape in [DioramaShape.circular, .hexagonal, .rectangular(width: 1, depth: 1)] {
            let fixed = DioramaBoundary.make(shape: shape, extent: SIMD2(repeating: 1))
            for offset in [SIMD2<Float>(0.2, -0.15), SIMD2(-0.12, 0.18), .zero] {
                let moved = DioramaBoundary(vertices: fixed.vertices.map { $0 + offset })
                let prism = BoundaryPrism(boundary: moved, scale: 1)
                let source = Self.lattice(extent: 2, step: 0.1)
                var gpuResult: Summary?
                var positions: [SIMD2<Float>] = [], indices: [UInt32] = []
                var cuts: [Tiles3DCutEdge] = []
                gpu.clip([(uri: "panned", source: source)], to: prism) { _, outcome in
                    gpuResult = Self.summarise(outcome)
                    if case .clipped(let vertices, let outputIndices, let cutEdges, _) = outcome {
                        positions = vertices.map { SIMD2($0.px, $0.pz) }
                        indices = Array(outputIndices)
                        cuts = cutEdges
                    }
                }
                let output = try #require(gpuResult)
                let cpu = Self.onCPU(source, to: prism)
                // Translation can split near-zero fragments differently (~3e-9 m² observed).
                // Compare rendered geometry and coverage, not an identical triangulation count.
                #expect(abs(output.area - cpu.area) < cpu.area * 1e-4)
                #expect(output.cutEdgeCount == cpu.cutEdgeCount)
                #expect(simd_distance(output.bounds.min, cpu.bounds.min) < 1e-3)
                #expect(simd_distance(output.bounds.max, cpu.bounds.max) < 1e-3)
                for cut in cuts {
                    for endpoint in [cut.a, cut.b] {
                        #expect(fixed.distance(from: SIMD2(endpoint.x, endpoint.z) - offset,
                            toEdge: cut.boundaryEdge) < 1e-5)
                    }
                }
                for row in 0..<21 {
                    for column in 0..<21 {
                        let point = SIMD2<Float>(Float(column) * 0.055 - 0.547,
                            Float(row) * 0.055 - 0.543)
                        if (0..<fixed.edgeCount).contains(where: { fixed.distance(from: point, toEdge: $0) < 1e-4 }) { continue }
                        let movedPoint = point + offset
                        let covered = stride(from: 0, to: indices.count, by: 3).contains { i in
                            let a = positions[Int(indices[i])], b = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
                            func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
                            let area = cross(b - a, c - a)
                            guard abs(area) > 1e-10 else { return false }
                            let sides = [cross(b - a, movedPoint - a) / area,
                                cross(c - b, movedPoint - b) / area, cross(a - c, movedPoint - c) / area]
                            return sides.allSatisfy { $0 >= -1e-5 }
                        }
                        #expect(covered == fixed.contains(point),
                            "Footprint at \(point), pan \(offset), boundary vertices \(fixed.vertices.count)")
                    }
                }
            }
        }
    }

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

    // MARK: - Batching

    @Test("A batch of tiles is cut as one dispatch without mixing them up")
    func batchKeepsTilesApart() throws {
        // The whole batch goes out as a single dispatch over one shared arena, so a tile's geometry
        // is found by offset and its threads by arithmetic on the group index. Both are silent when
        // wrong: a tile would come back holding a neighbour's triangles, or a slice of its own.
        // Sizes are deliberately uneven, since a tile is padded up to a whole number of threadgroups
        // and equal sizes would hide an off-by-one in that padding.
        guard let gpu = Tiles3DGPUClipper() else { return }
        let prism = Self.circle(radius: 1, sides: 128)
        let geometries = [
            Self.lattice(extent: 2, step: 0.1),
            Self.lattice(extent: 0.7, step: 0.13),
            Self.translated(Self.lattice(extent: 1.2, step: 0.11), by: SIMD3(0.4, 0, -0.3)),
            Self.lattice(extent: 1.5, step: 0.17),
            Self.translated(Self.lattice(extent: 0.5, step: 0.2), by: SIMD3(20, 0, 20)),
        ]

        var batched: [Int: Summary] = [:]
        var unresolved: [Int] = []
        gpu.clip(
            geometries.enumerated().map { (uri: "tile-\($0.offset)", source: $0.element) },
            to: prism
        ) { index, outcome in
            if let summary = Self.summarise(outcome) {
                batched[index] = summary
            } else {
                unresolved.append(index)
            }
        }

        #expect(unresolved.isEmpty)
        #expect(batched.count == geometries.count)
        for index in geometries.indices {
            let onGPU = try #require(batched[index])
            expect(onGPU, matches: Self.onCPU(geometries[index], to: prism))
        }
    }

    @Test("Geometry too coarse for a thread's polygon is handed back, not cut wrong")
    func coarseGeometryFallsBack() throws {
        // A thread's working polygon is capped, and a triangle wide enough to swallow a stretch of
        // the outline exceeds it. Measured here: against a 128-sided outline of radius 1, a lattice
        // of 0.37 steps overflows while 0.25 does not. What matters is that the overflow is reported
        // as `.unresolved` for the CPU to finish rather than quietly emitted half-clipped.
        guard let gpu = Tiles3DGPUClipper() else { return }
        let prism = Self.circle(radius: 1, sides: 128)

        var coarse: Tiles3DGPUClipper.Outcome?
        gpu.clip(
            [(uri: "coarse", source: Self.lattice(extent: 1.5, step: 0.37))], to: prism
        ) { _, outcome in coarse = outcome }
        guard case .unresolved = try #require(coarse) else {
            Issue.record("expected the cap to hand this tile back")
            return
        }

        // And the tile just inside the cap is still cut on the GPU, so the fallback is a boundary
        // rather than a blanket. The sliver band scales with the geometry: at these 0.25 steps the
        // two sides disagree about one triangle at 1e-10 where finer lattices agree, so the
        // threshold moves with them. Measured on this pair — CPU 272 triangles totalling
        // 3.805579708, GPU 271 totalling 3.805579715 — the counts are identical from 1e-8 up.
        let fine = Self.lattice(extent: 1.5, step: 0.25)
        expect(
            try clip(gpu: gpu, geometry: fine, to: prism, uri: "fine"),
            matches: Self.onCPU(fine, to: prism),
            ignoringSliversBelow: 1e-8
        )
    }

    @Test("An evicted tile's space is reused without corrupting the tile that takes it")
    func evictedSpaceIsReusable() throws {
        // Eviction returns a tile's range to the arena's free list, and the next upload of a fitting
        // size lands in it. A stale range or a bad reuse shows up as the new tile reading the old
        // one's vertices, which is exactly the geometry that would still look plausible.
        guard let gpu = Tiles3DGPUClipper() else { return }
        let prism = Self.circle(radius: 1, sides: 128)
        let first = Self.lattice(extent: 1.4, step: 0.12)
        let second = Self.translated(Self.lattice(extent: 1.4, step: 0.12), by: SIMD3(0.3, 0.2, -0.1))

        _ = try clip(gpu: gpu, geometry: first, to: prism, uri: "first")
        gpu.discard("first")

        let reused = try clip(gpu: gpu, geometry: second, to: prism, uri: "second")
        expect(reused, matches: Self.onCPU(second, to: prism))
    }

    // MARK: - Comparison

    private struct Summary {
        /// Every triangle's area, kept rather than counted, so how small is too small stays a choice
        /// the assertion makes — it moves with how coarse the geometry is.
        var areas: [Double] = []
        var cutEdgeCount = 0
        var bounds = BoundingBox(min: .zero, max: .zero)

        var triangleCount: Int { areas.count }
        var area: Double { areas.reduce(0, +) }
        /// Triangles big enough to draw something — see the note on the suite.
        func drawnTriangleCount(above threshold: Double) -> Int { areas.count { $0 > threshold } }
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
        expect(onGPU, matches: Self.onCPU(geometry, to: prism))
    }

    private func expect(
        _ onGPU: Summary,
        matches onCPU: Summary,
        ignoringSliversBelow threshold: Double = Self.degenerateArea
    ) {
        #expect(onGPU.drawnTriangleCount(above: threshold) == onCPU.drawnTriangleCount(above: threshold))
        #expect(onGPU.cutEdgeCount == onCPU.cutEdgeCount)
        // Surface area is the test that catches an inexact clip. Two clips can agree on triangle
        // counts while disagreeing about where the cut fell, and area is what notices.
        #expect(abs(onGPU.area - onCPU.area) <= onCPU.area * 1e-4)
        // An empty cut has no bounds to compare — the CPU leaves the sentinel it started from.
        guard onCPU.triangleCount > 0 else { return }
        #expect(simd_distance(onGPU.bounds.min, onCPU.bounds.min) < 1e-3)
        #expect(simd_distance(onGPU.bounds.max, onCPU.bounds.max) < 1e-3)
    }

    private static func onCPU(_ geometry: Tiles3DSourceGeometry, to prism: BoundaryPrism) -> Summary {
        let cut = Tiles3DClipper.clip(
            descriptors: geometry.descriptors,
            placement: geometry.placement,
            to: prism
        )
        return Summary(
            areas: areas(vertices: cut.vertices, indices: cut.indices),
            cutEdgeCount: cut.cutEdges.count,
            bounds: cut.bounds
        )
    }

    private static func summarise(_ outcome: Tiles3DGPUClipper.Outcome) -> Summary? {
        switch outcome {
        case .clipped(let vertices, let indices, let cutEdges, let bounds):
            return Summary(
                areas: areas(vertices: vertices, indices: indices),
                cutEdgeCount: cutEdges.count,
                bounds: bounds
            )
        case .empty:
            return Summary()
        case .unresolved:
            // Falling back is legitimate at runtime but not in these tests — the tiles here are well
            // inside what a thread's polygon can hold, so a fallback means the kernel failed rather
            // than declined.
            return nil
        }
    }

    /// Runs one tile through the kernel and summarises what came back.
    private func clip(
        gpu: Tiles3DGPUClipper,
        geometry: Tiles3DSourceGeometry,
        to prism: BoundaryPrism,
        uri: String = "test"
    ) throws -> Summary {
        var summary: Summary?
        gpu.clip([(uri: uri, source: geometry)], to: prism) { _, outcome in
            summary = Self.summarise(outcome)
        }
        return try #require(summary)
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
