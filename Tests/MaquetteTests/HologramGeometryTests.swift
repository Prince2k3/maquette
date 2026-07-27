import Foundation
import Testing
import simd
@testable import Maquette

/// The hologram draws its lines as real triangles, not as a shader effect — `CustomMaterial` is
/// unavailable on visionOS and `ShaderGraphMaterial` only loads from a Reality Composer Pro asset,
/// which this package deliberately does not ship. So the ribbon builder is load-bearing, and the
/// things it can get wrong are geometric: a ribbon of the wrong width, a ribbon flattened when it
/// should drape, or one wound face-down and invisible from above.
@Suite("Hologram Geometry Tests")
struct HologramGeometryTests {

    static func segment(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>
    ) -> ContourExtractor.Segment {
        ContourExtractor.Segment(a: a, b: b)
    }

    static func triangles(of mesh: HologramMesh) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        var base = 0
        while base + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[base])].position
            let b = mesh.vertices[Int(mesh.indices[base + 1])].position
            let c = mesh.vertices[Int(mesh.indices[base + 2])].position
            faces.append((a, b, c))
            base += 3
        }
        return faces
    }

    // MARK: - Ribbons

    @Test("A segment becomes one quad of the requested width")
    func ribbonHasTheRequestedWidth() {
        var mesh = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(1, 0, 0))],
            width: 0.04, yOffset: 0, into: &mesh
        )

        #expect(mesh.vertices.count == 4)
        #expect(mesh.indices.count == 6)

        let bounds = mesh.bounds
        // Across the line: exactly the full width.
        #expect(abs((bounds.max.z - bounds.min.z) - 0.04) < 1e-5)
        // Along it: the segment plus half a width of overhang at each end, which is what fills the
        // notch on the outside of a bend without walking the segments into paths first.
        #expect(abs((bounds.max.x - bounds.min.x) - 1.04) < 1e-5)
    }

    /// A ribbon wound face-down is not a subtle defect — it disappears from the only angle anyone
    /// looks at a diorama from, and nothing about the vertex count says so.
    @Test("Ribbon triangles face up")
    func ribbonTrianglesFaceUp() {
        var mesh = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(1, 0, 0)),
             Self.segment(SIMD3(1, 0, 0), SIMD3(1, 0, 1)),
             Self.segment(SIMD3(1, 0, 1), SIMD3(0.3, 0, 0.7))],
            width: 0.02, yOffset: 0, into: &mesh
        )

        let faces = Self.triangles(of: mesh)
        #expect(faces.count == 6)
        for (a, b, c) in faces {
            #expect(simd_cross(b - a, c - a).y > 0)
        }
    }

    /// The same routine serves flat contours and draped graticules, and the only thing that makes
    /// that work is each vertex keeping the height it was extracted at. Averaging the two ends would
    /// look identical on a contour and would cut a graticule line straight through a hill.
    @Test("A ribbon keeps each end's own height")
    func ribbonDrapesOverRelief() {
        var mesh = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(1, 1, 0))],
            width: 0.02, yOffset: 0.5, into: &mesh
        )

        let heights = mesh.vertices.map(\.position.y)
        #expect(abs((heights.min() ?? 0) - 0.5) < 1e-5)
        #expect(abs((heights.max() ?? 0) - 1.5) < 1e-5)
    }

    @Test("A zero-length segment draws nothing rather than dividing by its own length")
    func degenerateSegmentsAreSkipped() {
        var mesh = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0.5, 0.2, 0.5), SIMD3(0.5, 0.9, 0.5))],
            width: 0.02, yOffset: 0, into: &mesh
        )
        // Purely vertical: no horizontal extent to build a ribbon across.
        #expect(mesh.isEmpty)

        var second = HologramMesh()
        HologramGeometry.addRibbons([], width: 0.02, yOffset: 0, into: &second)
        #expect(second.isEmpty)

        var third = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(1, 0, 0))],
            width: 0, yOffset: 0, into: &third
        )
        #expect(third.isEmpty)
    }

    @Test("Several line sets accumulate into one mesh")
    func ribbonsAccumulate() {
        var mesh = HologramMesh()
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(1, 0, 0))],
            width: 0.02, yOffset: 0, into: &mesh
        )
        HologramGeometry.addRibbons(
            [Self.segment(SIMD3(0, 0, 0), SIMD3(0, 0, 1))],
            width: 0.02, yOffset: 0, into: &mesh
        )
        #expect(mesh.vertices.count == 8)
        #expect(mesh.indices.count == 12)

        mesh.removeAll()
        #expect(mesh.isEmpty)
        #expect(mesh.vertices.isEmpty)
    }

    // MARK: - Motes

    @Test("Motes land inside the outline and inside the height band")
    func motesRespectTheirBounds() {
        // Concave on purpose: an inscribed-circle placement would pass a convex outline and quietly
        // hang motes in the notch of this one.
        let boundary = DioramaBoundary(vertices: [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1),
            SIMD2(0.6, 0.4), SIMD2(0, 1),
        ])
        var mesh = HologramMesh()
        HologramGeometry.addMotes(
            count: 120, in: boundary, from: 0.2, to: 0.8,
            size: 0.004, seed: 7, into: &mesh
        )
        #expect(!mesh.isEmpty)

        // Each mote is an octahedron, so its own radius is the tolerance on the band.
        let radius = Float(0.004) * 1.5
        for vertex in mesh.vertices {
            #expect(vertex.position.y > 0.2 - radius)
            #expect(vertex.position.y < 0.8 + radius)
        }

        // Centres, which is what placement actually decides, must be strictly inside.
        let centres = stride(from: 0, to: mesh.vertices.count, by: 6).map { index -> SIMD2<Float> in
            let top = mesh.vertices[index].position
            let bottom = mesh.vertices[index + 1].position
            let centre = (top + bottom) / 2
            return SIMD2(centre.x, centre.z)
        }
        #expect(centres.count == 120)
        for centre in centres {
            #expect(boundary.contains(centre), "mote placed outside the outline at \(centre)")
        }
    }

    /// Motes are seeded rather than random because a field that reshuffled on every refresh would
    /// flicker for the whole of a pan — the effect refreshes once per pan step.
    @Test("The same seed places the same motes")
    func motesAreReproducible() {
        let boundary = DioramaBoundary(vertices: [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ])

        func place(seed: UInt64) -> [SIMD3<Float>] {
            var mesh = HologramMesh()
            HologramGeometry.addMotes(
                count: 30, in: boundary, from: 0, to: 1, size: 0.01, seed: seed, into: &mesh
            )
            return mesh.vertices.map(\.position)
        }

        #expect(place(seed: 42) == place(seed: 42))
        #expect(place(seed: 42) != place(seed: 43))
    }

    @Test("Asking for no motes builds nothing")
    func moteDegenerateCases() {
        let boundary = DioramaBoundary(vertices: [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ])
        var mesh = HologramMesh()
        HologramGeometry.addMotes(count: 0, in: boundary, from: 0, to: 1,
                                  size: 0.01, seed: 1, into: &mesh)
        #expect(mesh.isEmpty)

        HologramGeometry.addMotes(count: 10, in: boundary, from: 1, to: 1,
                                  size: 0.01, seed: 1, into: &mesh)
        #expect(mesh.isEmpty)

        HologramGeometry.addMotes(count: 10, in: boundary, from: 0, to: 1,
                                  size: 0, seed: 1, into: &mesh)
        #expect(mesh.isEmpty)
    }

    @Test("The seeded generator stays inside the unit interval")
    func generatorRange() {
        var random = SplitMix64(seed: 0)
        for _ in 0..<5_000 {
            let value = random.nextUnit()
            #expect(value >= 0 && value < 1)
        }
    }
}

/// The style's numbers reach geometry directly — a negative width or an opacity above one would
/// either build inverted ribbons or hand RealityKit a blend factor it clamps silently.
@Suite("Hologram Style Tests")
struct HologramStyleTests {
    @Test("Out-of-range values are clamped rather than carried into geometry")
    func styleClampsItsInputs() {
        let style = HologramStyle(
            surfaceOpacity: 4,
            lineWidth: -0.5,
            glowWidth: 0.2,
            glowOpacity: -1,
            graticuleDivisions: -6,
            moteCount: -20
        )
        #expect(style.surfaceOpacity == 1)
        #expect(style.lineWidth == 0)
        // A halo narrower than the line it sits behind is not a halo.
        #expect(style.glowWidth == 1)
        #expect(style.glowOpacity == 0)
        #expect(style.graticuleDivisions == 0)
        #expect(style.moteCount == 0)
    }

    @Test("An effect's backdrop follows its body colour")
    func backgroundFollowsTheBody() {
        #expect(DioramaEffect.none.backgroundColor == nil)
        #expect(DioramaEffect.hologram.backgroundColor == HologramStyle.standard.surfaceColor)
        #expect(DioramaEffect.hologram(.amber).backgroundColor == HologramStyle.amber.surfaceColor)
        #expect(DioramaEffect.hologram(.amber) != DioramaEffect.hologram(.survey))
        #expect(DioramaEffect.hologram == DioramaEffect.hologram(.standard))
    }
}
