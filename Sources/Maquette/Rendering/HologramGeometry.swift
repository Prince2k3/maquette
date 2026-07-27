import Foundation
import RealityKit
import simd

/// Geometry accumulated for one hologram pass, in the layout `Tiles3DMeshBuffer` draws from.
///
/// The lines are real triangles rather than a shader effect, which is not a stylistic choice:
/// `CustomMaterial` is unavailable on visionOS and `ShaderGraphMaterial` only loads from a Reality
/// Composer Pro asset, which this package deliberately does not ship. Geometry plus an unlit
/// material is the one route that renders the same on all four platforms.
struct HologramMesh {
    private(set) var vertices: [Tiles3DVertex] = []
    private(set) var indices: [UInt32] = []
    private var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    var isEmpty: Bool { indices.isEmpty }

    var bounds: BoundingBox {
        isEmpty ? BoundingBox() : BoundingBox(min: lo, max: hi)
    }

    mutating func reserve(vertices count: Int, indices indexCount: Int) {
        vertices.reserveCapacity(count)
        indices.reserveCapacity(indexCount)
    }

    mutating func removeAll() {
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        lo = SIMD3(repeating: .greatestFiniteMagnitude)
        hi = SIMD3(repeating: -.greatestFiniteMagnitude)
    }

    /// Appends a vertex and returns its index.
    @discardableResult
    mutating func append(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) -> UInt32 {
        lo = simd_min(lo, position)
        hi = simd_max(hi, position)
        vertices.append(Tiles3DVertex(position: position, normal: normal, uv: uv))
        return UInt32(vertices.count - 1)
    }

    mutating func appendTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(contentsOf: [a, b, c])
    }
}

/// Builds the hologram's drawable pieces: the ribbons that carry every line.
enum HologramGeometry {
    /// Turns isoline segments into flat ribbons lying just above the surface they came from.
    ///
    /// Each segment becomes its own quad. Segments that meet at a shared endpoint therefore leave a
    /// wedge-shaped notch on the outside of every bend, so each quad is extended by half its width at
    /// both ends — enough to fill the notch at any angle a sampled terrain grid produces, and cheaper
    /// than mitring joints that would first have to be found by walking the segments into paths.
    ///
    /// Every vertex keeps the Y it was extracted at, plus `yOffset`. That is what lets the same code
    /// serve both uses: elevation contours come out lying flat, and graticule lines come out draped
    /// over the relief.
    ///
    /// - Parameters:
    ///   - segments: Isoline segments, in the chunk's own space.
    ///   - width: Full width of the ribbon in diorama meters.
    ///   - yOffset: How far to lift the ribbon off the surface, so it does not z-fight with it.
    ///   - mesh: Accumulator, so several line sets can share one mesh and one draw.
    static func addRibbons(
        _ segments: [ContourExtractor.Segment],
        width: Float,
        yOffset: Float,
        into mesh: inout HologramMesh
    ) {
        guard width > 0, !segments.isEmpty else { return }
        let half = width / 2
        let up = SIMD3<Float>(0, 1, 0)

        for segment in segments {
            let flat = SIMD2(segment.b.x - segment.a.x, segment.b.z - segment.a.z)
            let length = simd_length(flat)
            guard length > 1e-7 else { continue }
            let direction = flat / length
            // The outward perpendicular in the horizontal plane, the same construction the boundary
            // uses for its wall normals.
            let side = SIMD3<Float>(-direction.y, 0, direction.x) * half
            let overhang = SIMD3<Float>(direction.x, 0, direction.y) * half

            let a = SIMD3(segment.a.x, segment.a.y + yOffset, segment.a.z) - overhang
            let b = SIMD3(segment.b.x, segment.b.y + yOffset, segment.b.z) + overhang

            let v0 = mesh.append(position: a + side, normal: up, uv: SIMD2(0, 0))
            let v1 = mesh.append(position: a - side, normal: up, uv: SIMD2(1, 0))
            let v2 = mesh.append(position: b + side, normal: up, uv: SIMD2(0, 1))
            let v3 = mesh.append(position: b - side, normal: up, uv: SIMD2(1, 1))

            // Wound to face +Y. The material draws both sides, but a line seen edge-on from beneath
            // the chunk should still be the same line.
            mesh.appendTriangle(v0, v2, v1)
            mesh.appendTriangle(v2, v3, v1)
        }
    }
}
