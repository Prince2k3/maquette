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

/// Builds the hologram's drawable pieces: the ribbons that carry every line, and the motes.
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

    /// Suspends small motes in the air above the chunk, inside its outline.
    ///
    /// Each is an octahedron rather than a billboarded quad: it reads as a point of light from any
    /// angle without needing to be turned towards a camera every frame, which matters on visionOS
    /// where there are two of those and neither is the app's to track.
    ///
    /// Placement is seeded rather than random so a chunk looks the same every time it loads, and so
    /// the motes stay put while the terrain pans beneath them.
    static func addMotes(
        count: Int,
        in boundary: DioramaBoundary,
        from lowY: Float,
        to highY: Float,
        size: Float,
        seed: UInt64,
        into mesh: inout HologramMesh
    ) {
        guard count > 0, size > 0, highY > lowY else { return }
        var random = SplitMix64(seed: seed)

        var placed = 0
        // Rejection sampling against the outline, which is exact for concave shapes where an
        // inscribed region would not be. Bounded so a pathological outline cannot spin here.
        var attempts = 0
        let limit = count * 32
        while placed < count && attempts < limit {
            attempts += 1
            let point = boundary.minCorner + SIMD2(
                random.nextUnit() * boundary.extent.x,
                random.nextUnit() * boundary.extent.y
            )
            guard boundary.contains(point) else { continue }
            placed += 1

            let y = lowY + random.nextUnit() * (highY - lowY)
            // Vary the size a little so the field reads as depth rather than as a uniform stipple.
            let radius = size * (0.5 + random.nextUnit())
            addOctahedron(center: SIMD3(point.x, y, point.y), radius: radius, into: &mesh)
        }
    }

    private static func addOctahedron(
        center: SIMD3<Float>,
        radius: Float,
        into mesh: inout HologramMesh
    ) {
        let offsets: [SIMD3<Float>] = [
            SIMD3(0, radius, 0), SIMD3(0, -radius, 0),
            SIMD3(radius, 0, 0), SIMD3(-radius, 0, 0),
            SIMD3(0, 0, radius), SIMD3(0, 0, -radius),
        ]
        var corner: [UInt32] = []
        corner.reserveCapacity(6)
        for offset in offsets {
            corner.append(mesh.append(
                position: center + offset,
                normal: simd_normalize(offset),
                uv: SIMD2(0.5, 0.5)
            ))
        }

        let (top, bottom) = (corner[0], corner[1])
        let ring = [corner[4], corner[2], corner[5], corner[3]]  // +Z, +X, -Z, -X
        for i in 0..<4 {
            let a = ring[i]
            let b = ring[(i + 1) % 4]
            mesh.appendTriangle(top, a, b)
            mesh.appendTriangle(bottom, b, a)
        }
    }
}

/// A small deterministic generator, so a chunk's motes are the same every load.
///
/// Written out rather than taken from `SystemRandomNumberGenerator` precisely because the system one
/// is not reproducible, and a field of motes that reshuffled on every effect refresh would flicker
/// during a pan.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<1`.
    mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
