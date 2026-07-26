import Foundation
import RealityKit
import Testing
import simd
@testable import Maquette

@Suite("3D Tiles Clipper Tests")
struct Tiles3DClipperTests {
    /// A prism raised from a unit-diameter circle. `scale: 1` keeps it in the same units as the
    /// test geometry rather than converting into tile space.
    private func circlePrism(diameter: Float = 1.0) -> BoundaryPrism {
        BoundaryPrism(
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(diameter, diameter)),
            scale: 1
        )
    }

    private func descriptor(positions: [SIMD3<Float>], indices: [UInt32]) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "test")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(positions.map { _ in SIMD3<Float>(0, 1, 0) })
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(positions.map { _ in SIMD2<Float>(0, 0) })
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private func positions(of result: Tiles3DClipper.Result) -> [SIMD3<Float>] {
        result.vertices.map(\.position)
    }

    private func triangleCount(of result: Tiles3DClipper.Result) -> Int {
        result.indices.count / 3
    }

    // MARK: - Basic Containment

    @Test("Geometry entirely inside the outline is kept")
    func insideGeometrySurvives() {
        let mesh = descriptor(
            positions: [SIMD3(-0.1, 0, -0.1), SIMD3(0.1, 0, -0.1), SIMD3(0, 0, 0.1)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )
        #expect(triangleCount(of: result) == 1)
    }

    @Test("Geometry entirely outside the outline is dropped")
    func outsideGeometryIsDropped() {
        let mesh = descriptor(
            positions: [SIMD3(5, 0, 5), SIMD3(5.2, 0, 5), SIMD3(5, 0, 5.2)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )
        #expect(result.isEmpty)
    }

    @Test("Geometry straddling the outline is cut to it")
    func straddlingGeometryIsCut() {
        // A long triangle running from inside the circle out past its edge.
        let mesh = descriptor(
            positions: [SIMD3(0, 0, -0.05), SIMD3(0, 0, 0.05), SIMD3(3, 0, 0)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )

        #expect(!result.isEmpty, "The inside portion should survive")
        for position in positions(of: result) {
            let distance = sqrt(position.x * position.x + position.z * position.z)
            #expect(distance <= 0.5 + 0.01, "Vertex at \(position) escaped the outline")
        }
    }

    // MARK: - The Case a Two-Dimensional Clip Would Break

    @Test("Vertical faces survive the cut")
    func verticalFacesSurvive() {
        // A building facade: zero footprint area, so projecting onto the horizontal plane would
        // collapse it to a line and delete it.
        let mesh = descriptor(
            positions: [SIMD3(0.1, 0, 0), SIMD3(0.2, 0, 0), SIMD3(0.1, 0.3, 0)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )

        #expect(triangleCount(of: result) == 1, "A vertical facade inside the outline must be kept")
        #expect(positions(of: result).contains { $0.y > 0.2 }, "The facade's height should survive")
    }

    @Test("Vertical faces are cut where they cross the outline")
    func verticalFacesAreCut() {
        // A facade running from inside the circle out past its edge, still with no footprint area.
        let mesh = descriptor(
            positions: [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(0, 0.3, 0)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )

        #expect(!result.isEmpty)
        for position in positions(of: result) {
            #expect(position.x <= 0.5 + 0.01, "Facade extends past the outline at \(position)")
        }
    }

    // MARK: - Attribute Interpolation

    @Test("Heights are interpolated along the cut")
    func heightsInterpolateAcrossTheCut() {
        // A ramp climbing from y=0 at the origin to y=1 at x=1, cut at the circle's edge (x=0.5).
        let mesh = descriptor(
            positions: [SIMD3(0, 0, -0.05), SIMD3(0, 0, 0.05), SIMD3(1, 1, 0)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )

        let maximumHeight = positions(of: result).map(\.y).max() ?? 0
        // Cutting at roughly half way along the ramp should leave roughly half its height, not
        // the full height (no interpolation) or zero (attributes dropped).
        #expect(maximumHeight > 0.3 && maximumHeight < 0.7,
                "Height at the cut should be interpolated, got \(maximumHeight)")
    }

    @Test("Placement is baked into the vertices")
    func placementIsBaked() {
        // A triangle sitting at the origin, moved to +X by its placement.
        let mesh = descriptor(
            positions: [SIMD3(-0.05, 0, -0.05), SIMD3(0.05, 0, -0.05), SIMD3(0, 0, 0.05)],
            indices: [0, 1, 2]
        )
        var placement = matrix_identity_float4x4
        placement.columns.3 = SIMD4(0.3, 0, 0, 1)

        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: placement,
            to: circlePrism()
        )

        #expect(!result.isEmpty)
        let meanX = positions(of: result).map(\.x).reduce(0, +) / Float(positions(of: result).count)
        #expect(abs(meanX - 0.3) < 0.05, "Placement should be applied to the vertices, got \(meanX)")
    }

    @Test("Placement moving geometry out of the outline drops it")
    func placementCanMoveGeometryOutside() {
        let mesh = descriptor(
            positions: [SIMD3(-0.05, 0, -0.05), SIMD3(0.05, 0, -0.05), SIMD3(0, 0, 0.05)],
            indices: [0, 1, 2]
        )
        var placement = matrix_identity_float4x4
        placement.columns.3 = SIMD4(9, 0, 0, 1)

        let result = Tiles3DClipper.clip(descriptors: [mesh], placement: placement, to: circlePrism())
        #expect(result.isEmpty)
    }

    @Test("A triangle far larger than the outline is cut down to it")
    func hugeTriangleIsCutToOutline() {
        // 3D Tiles arrive as coarse tiles spanning kilometres against an outline of a few hundred
        // metres, so the subject is routinely far bigger than the clip region.
        let mesh = descriptor(
            positions: [SIMD3(-50, 0, -50), SIMD3(50, 0, -50), SIMD3(0, 0, 50)],
            indices: [0, 1, 2]
        )
        let result = Tiles3DClipper.clip(
            descriptors: [mesh],
            placement: matrix_identity_float4x4,
            to: circlePrism()
        )

        #expect(!result.isEmpty, "A triangle covering the whole outline must leave geometry")

        // What survives should be the outline itself.
        var area: Float = 0
        for start in stride(from: 0, to: result.indices.count, by: 3) {
            let a = result.vertices[Int(result.indices[start])].position
            let b = result.vertices[Int(result.indices[start + 1])].position
            let c = result.vertices[Int(result.indices[start + 2])].position
            let ab = SIMD2(b.x - a.x, b.z - a.z)
            let ac = SIMD2(c.x - a.x, c.z - a.z)
            area += abs(ab.x * ac.y - ab.y * ac.x) / 2
        }
        let expected = Float.pi * 0.25
        #expect(abs(area - expected) / expected < 0.02,
                "Clipped area \(area) should match the circle's \(expected)")
    }

    @Test("Geometry offset far from the origin still clips correctly")
    func distantGeometryClips() {
        // Mirrors what the streamed tiles actually look like: a large tile whose origin sits
        // kilometres away but which still overlaps the outline.
        let prism = BoundaryPrism(
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(2400, 2400)),
            scale: 1
        )
        // Sized so that, once the placement has moved it, the triangle still covers the origin.
        let mesh = descriptor(
            positions: [SIMD3(-8000, 0, -8000), SIMD3(8000, 0, -8000), SIMD3(0, 0, 8000)],
            indices: [0, 1, 2]
        )
        var placement = matrix_identity_float4x4
        placement.columns.3 = SIMD4(2873, -422, -890, 1)

        let result = Tiles3DClipper.clip(descriptors: [mesh], placement: placement, to: prism)
        #expect(!result.isEmpty, "A tile overlapping the outline must leave geometry")

        for position in positions(of: result) {
            let distance = sqrt(position.x * position.x + position.z * position.z)
            #expect(distance <= 1200 + 5, "Vertex at \(position) escaped the outline")
        }
    }

    // MARK: - Concave Outlines

    @Test("A concave outline keeps the geometry in its arms")
    func concaveOutlineKeepsArms() {
        // An L covering three quadrants; the notch is the +X/+Z quadrant.
        let boundary = DioramaBoundary(vertices: [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0),
            SIMD2(0, 0), SIMD2(0, 0.5), SIMD2(-0.5, 0.5),
        ])
        let prism = BoundaryPrism(boundary: boundary, scale: 1)
        #expect(prism.pieces.count > 1, "A concave outline must be split into convex pieces")

        // Sits in the notch, and must be removed.
        let inNotch = descriptor(
            positions: [SIMD3(0.2, 0, 0.2), SIMD3(0.3, 0, 0.2), SIMD3(0.2, 0, 0.3)],
            indices: [0, 1, 2]
        )
        #expect(Tiles3DClipper.clip(
            descriptors: [inNotch], placement: matrix_identity_float4x4, to: prism
        ).isEmpty)

        // Sits in an arm, and must survive — the reflex corner should not eat it.
        let inArm = descriptor(
            positions: [SIMD3(-0.3, 0, 0.2), SIMD3(-0.2, 0, 0.2), SIMD3(-0.3, 0, 0.3)],
            indices: [0, 1, 2]
        )
        #expect(!Tiles3DClipper.clip(
            descriptors: [inArm], placement: matrix_identity_float4x4, to: prism
        ).isEmpty)
    }

    @Test("Convex outlines clip as a single piece")
    func convexOutlinesAreOnePiece() {
        #expect(circlePrism().pieces.count == 1)
        #expect(BoundaryPrism(
            boundary: DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(1, 1)),
            scale: 1
        ).pieces.count == 1)
    }

    @Test("Convexity detection separates convex from concave")
    func convexityDetection() {
        let square: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1),
        ]
        #expect(BoundaryPrism.isConvex(square))

        let lShape: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 0),
            SIMD2(0, 0), SIMD2(0, 1), SIMD2(-1, 1),
        ]
        #expect(!BoundaryPrism.isConvex(lShape))
    }

    // MARK: - Scale

    @Test("The prism is scaled into the geometry's space")
    func prismScalesIntoGeometrySpace() {
        // Tile geometry is in real-world meters; a 0.8 m outline at 1/1000 scale covers 800 m.
        let prism = BoundaryPrism(
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)),
            scale: 0.001
        )
        #expect(abs(prism.upperBound.x - 400) < 1)
        #expect(prism.contains(SIMD2(300, 0)))
        #expect(!prism.contains(SIMD2(500, 0)))
    }
}
