import Foundation
import RealityKit
import Testing
import simd
@testable import Maquette

@Suite("3D Tiles Cut Wall Tests")
struct Tiles3DCutWallTests {
    /// A two-metre square centred on the origin. Scale 1, so diorama space and geometry space
    /// coincide and the numbers in these tests are the numbers the clipper sees.
    private static func square() -> BoundaryPrism {
        BoundaryPrism(
            boundary: DioramaBoundary(vertices: [
                SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1),
            ]),
            scale: 1
        )
    }

    // MARK: - Recognising a cut

    @Test("A segment lying along the outline is recognised as a cut")
    func segmentOnOutlineIsACut() {
        let prism = Self.square()
        let index = prism.boundaryEdge(along: SIMD2(-0.5, -1), SIMD2(0.5, -1))
        #expect(index != nil)
        // And it is the edge the segment actually sits on, not merely some edge.
        if let index {
            #expect(prism.boundary.distance(from: SIMD2(0, -1), toEdge: index) < 1e-4)
        }
    }

    @Test("A chord between two points on the outline is not a cut")
    func chordIsNotACut() {
        // Both endpoints sit on the outline — on opposite corners — but the segment runs through
        // the middle of the model. Walling it would put a wall through the middle of the model,
        // and a clipped triangle produces this shape routinely.
        let prism = Self.square()
        #expect(prism.boundaryEdge(along: SIMD2(-1, -1), SIMD2(1, 1)) == nil)
    }

    @Test("A segment inside the outline is not a cut")
    func interiorSegmentIsNotACut() {
        let prism = Self.square()
        #expect(prism.boundaryEdge(along: SIMD2(-0.5, 0), SIMD2(0.5, 0)) == nil)
    }

    @Test("A degenerate segment is not a cut")
    func degenerateSegmentIsNotACut() {
        // Clipping routinely emits coincident points where a triangle's corner already sat on the
        // outline. Extruding one would add a zero-width quad and, worse, a normal from a zero
        // direction vector.
        let prism = Self.square()
        #expect(prism.boundaryEdge(along: SIMD2(0, -1), SIMD2(0, -1)) == nil)
    }

    // MARK: - Clipping reports its cuts

    @Test("Clipping a straddling triangle reports the segment it cut along")
    func clippingReportsItsCut() {
        let prism = Self.square()
        // Reaches from inside the square out past the +X edge, so the clip has to slice it.
        let result = Tiles3DClipper.clip(
            descriptors: [Self.triangle(
                SIMD3(0, 10, -0.5),
                SIMD3(3, 10, 0),
                SIMD3(0, 10, 0.5)
            )],
            placement: matrix_identity_float4x4,
            to: prism
        )

        #expect(!result.descriptors.isEmpty)
        #expect(!result.cutEdges.isEmpty)
        // Everything reported has to actually lie on the outline it claims to.
        for cut in result.cutEdges {
            let a = SIMD2(cut.a.x, cut.a.z)
            let b = SIMD2(cut.b.x, cut.b.z)
            #expect(prism.boundary.distance(from: a, toEdge: cut.boundaryEdge) < 1e-3)
            #expect(prism.boundary.distance(from: b, toEdge: cut.boundaryEdge) < 1e-3)
        }
    }

    @Test("A triangle wholly inside the outline is never cut")
    func interiorTriangleIsNotCut() {
        // The common case by a wide margin, and the one that must stay free: an interior tile is
        // kept whole without being clipped at all, so it can have no cut to report.
        let prism = Self.square()
        let result = Tiles3DClipper.clip(
            descriptors: [Self.triangle(
                SIMD3(-0.4, 5, -0.4),
                SIMD3(0.4, 5, -0.4),
                SIMD3(0, 5, 0.4)
            )],
            placement: matrix_identity_float4x4,
            to: prism
        )

        #expect(!result.descriptors.isEmpty)
        #expect(result.cutEdges.isEmpty)
    }

    // MARK: - The wall itself

    @Test("The wall reaches from the terrain down to the floor with nothing left open")
    func wallSpansTerrainToFloor() {
        // The whole point of the wall: the gap between the model's cut rim and the tray's top is
        // what made a chunk of Half Dome read as a hollow shell floating over its own base.
        let prism = Self.square()
        let floorY: Float = -20
        let geometry = Self.wall(of: prism, floorY: floorY)

        let bottoms = geometry.positions.filter { abs($0.y - floorY) < 1e-4 }
        #expect(bottoms.count == geometry.positions.count / 2)
        #expect(geometry.positions.allSatisfy { $0.y >= floorY - 1e-4 })
    }

    @Test("Wall normals are horizontal and face away from the model")
    func wallNormalsFaceOutward() {
        // A wall shaded from an inward normal is lit as though the outside of the chunk were its
        // inside, which reads as a dark band rather than as earth — and is invisible in any count
        // of vertices or triangles.
        let prism = Self.square()
        let geometry = Self.wall(of: prism, floorY: -20)

        for (index, normal) in geometry.normals.enumerated() {
            #expect(abs(normal.y) < 1e-5)
            #expect(abs(simd_length(normal) - 1) < 1e-4)

            let position = geometry.positions[index]
            let outward = simd_dot(SIMD2(normal.x, normal.z), SIMD2(position.x, position.z))
            #expect(outward > 0)
        }
    }

    @Test("The strata run from the floor at V = 0 upward, within the texture")
    func strataAreAnchoredToTheFloor() {
        // The texture's V axis runs from the deepest layer at 0 to the surface at 1. A wall whose
        // V escapes that range samples past the palette; one that does not start at 0 at the floor
        // shows the bands sliding as the datum settles during streaming.
        let prism = Self.square()
        let floorY: Float = -20
        let geometry = Self.wall(of: prism, floorY: floorY)

        for (index, uv) in geometry.uvs.enumerated() {
            #expect(uv.y >= 0 && uv.y <= 1)
            if abs(geometry.positions[index].y - floorY) < 1e-4 {
                #expect(uv.y == 0)
            }
        }
    }

    @Test("A lone tower on the rim does not squash the strata on every other wall")
    func outlierDoesNotSetTheScale() {
        // In a city the outline cuts through buildings. Normalizing against the tallest cut would
        // let one tower push every other wall's bands into a sliver at the bottom of the texture,
        // so the reference height tracks the ground the wall is mostly made of and lets the
        // outlier clamp at the top band instead.
        let prism = Self.square()
        let floorY: Float = 0

        var edges = (0..<20).map { index -> Tiles3DCutEdge in
            let x = Float(index) / 20 * 2 - 1
            return Tiles3DCutEdge(
                a: SIMD3(x, 10, -1),
                b: SIMD3(x + 0.05, 10, -1),
                boundaryEdge: Self.edgeIndex(of: prism, near: SIMD2(x, -1))
            )
        }
        edges.append(Tiles3DCutEdge(
            a: SIMD3(0.5, 400, -1),
            b: SIMD3(0.55, 400, -1),
            boundaryEdge: Self.edgeIndex(of: prism, near: SIMD2(0.5, -1))
        ))

        let geometry = try! #require(Tiles3DCutWall.buildGeometry(edges: edges, floorY: floorY, prism: prism))

        // The ground walls still reach the top of the texture rather than being crushed by the
        // tower, which clamps.
        let groundTops = zip(geometry.positions, geometry.uvs)
            .filter { abs($0.0.y - 10) < 1e-4 }
            .map(\.1.y)
        #expect(!groundTops.isEmpty)
        #expect(groundTops.allSatisfy { $0 > 0.9 })
    }

    @Test("Cuts already at or below the floor contribute no wall")
    func submergedCutsAreSkipped() {
        let prism = Self.square()
        let edges = [Tiles3DCutEdge(
            a: SIMD3(-0.5, -30, -1),
            b: SIMD3(0.5, -30, -1),
            boundaryEdge: Self.edgeIndex(of: prism, near: SIMD2(0, -1))
        )]
        #expect(Tiles3DCutWall.buildGeometry(edges: edges, floorY: -20, prism: prism) == nil)
    }

    @Test("No cuts means no wall rather than an empty mesh")
    func noCutsMeansNoWall() {
        #expect(Tiles3DCutWall.buildGeometry(edges: [], floorY: 0, prism: Self.square()) == nil)
    }

    // MARK: - Support

    private static func triangle(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "test")
        descriptor.positions = MeshBuffers.Positions([a, b, c])
        descriptor.normals = MeshBuffers.Normals([SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0)])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([.zero, .zero, .zero])
        descriptor.primitives = .triangles([0, 1, 2])
        return descriptor
    }

    /// A wall along all four sides, with the terrain at differing heights so V has a range to span.
    private static func wall(of prism: BoundaryPrism, floorY: Float) -> Tiles3DCutWall.Geometry {
        var edges: [Tiles3DCutEdge] = []
        for index in 0..<prism.boundary.edgeCount {
            let (start, end) = prism.boundary.edge(index)
            let height = Float(index + 1) * 4
            edges.append(Tiles3DCutEdge(
                a: SIMD3(start.x, height, start.y),
                b: SIMD3(end.x, height + 2, end.y),
                boundaryEdge: index
            ))
        }
        return try! #require(Tiles3DCutWall.buildGeometry(edges: edges, floorY: floorY, prism: prism))
    }

    private static func edgeIndex(of prism: BoundaryPrism, near point: SIMD2<Float>) -> Int {
        (0..<prism.boundary.edgeCount).min {
            prism.boundary.distance(from: point, toEdge: $0)
                < prism.boundary.distance(from: point, toEdge: $1)
        } ?? 0
    }
}
