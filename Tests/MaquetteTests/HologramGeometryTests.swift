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
}

/// The style's numbers reach geometry directly — a negative width or an opacity above one would
/// either build inverted ribbons or hand RealityKit a blend factor it clamps silently.
@Suite("Hologram Style Tests")
struct HologramStyleTests {
    @Test("Out-of-range values are clamped rather than carried into geometry")
    func styleClampsItsInputs() {
        let style = HologramStyle(
            surfaceOpacity: 4,
            earthOpacity: 9,
            lineWidth: -0.5,
            glowWidth: 0.2,
            glowOpacity: -1,
            graticuleDivisions: -6
        )
        #expect(style.surfaceOpacity == 1)
        #expect(style.earthOpacity == 1)
        #expect(style.lineWidth == 0)
        // A halo narrower than the line it sits behind is not a halo.
        #expect(style.glowWidth == 1)
        #expect(style.glowOpacity == 0)
        #expect(style.graticuleDivisions == 0)
    }

    /// The default has to leave the earth off, not merely allow it to be turned off: a solid black
    /// slab under the lines reads as an object on a table, which is the one thing a projection is
    /// not, and it is the whole reason `earthOpacity` starts at zero.
    @Test("The default hologram has no earth beneath it")
    func earthIsRemovedByDefault() {
        #expect(HologramStyle.standard.earthOpacity == 0)
        #expect(HologramStyle.survey.earthOpacity == 0)
        #expect(HologramStyle.amber.earthOpacity == 0)
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
