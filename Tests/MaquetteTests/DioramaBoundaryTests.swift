import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Diorama Boundary Tests")
struct DioramaBoundaryTests {
    /// Fan-triangulating a boundary in vertex order must produce upward-facing normals, since the
    /// chunk's top surface relies on that winding.
    private func fanNormalPointsUp(_ boundary: DioramaBoundary) -> Bool {
        let vertices = boundary.vertices
        let a = SIMD3(vertices[0].x, 0, vertices[0].y)
        let b = SIMD3(vertices[1].x, 0, vertices[1].y)
        let c = SIMD3(vertices[2].x, 0, vertices[2].y)
        return simd_cross(b - a, c - a).y > 0
    }

    @Test("Circular boundary is centered and sized to the extent")
    func circularBoundary() {
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))

        for vertex in boundary.vertices {
            #expect(abs(simd_length(vertex) - 0.5) < 0.001)
        }
        #expect(abs(boundary.extent.x - 1.0) < 0.01)
        #expect(abs(boundary.perimeter - Float.pi) < 0.01)
    }

    @Test("Rectangular boundary uses its explicit dimensions")
    func rectangularBoundary() {
        let boundary = DioramaBoundary.make(
            shape: .rectangular(width: 0.8, depth: 0.4),
            extent: SIMD2(0.8, 0.4)
        )

        #expect(boundary.vertices.count == 4)
        #expect(abs(boundary.extent.x - 0.8) < 0.0001)
        #expect(abs(boundary.extent.y - 0.4) < 0.0001)
        #expect(abs(boundary.perimeter - 2.4) < 0.0001)
    }

    @Test("Winding is normalized so fan triangulation faces up", arguments: [
        DioramaShape.circular,
        DioramaShape.rectangular(width: 1.0, depth: 0.6),
        DioramaShape.roundedRectangular(width: 1.0, depth: 0.6, cornerRadius: 0.15),
        DioramaShape.hexagonal,
    ])
    func windingNormalization(shape: DioramaShape) {
        let boundary = DioramaBoundary.make(shape: shape, extent: SIMD2(1.0, 0.6))
        #expect(fanNormalPointsUp(boundary))
    }

    @Test("Reversed input winding is corrected")
    func reversedInputIsCorrected() {
        let clockwise: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5),
        ]
        let forward = DioramaBoundary(vertices: clockwise)
        let backward = DioramaBoundary(vertices: clockwise.reversed())

        #expect(fanNormalPointsUp(forward))
        #expect(fanNormalPointsUp(backward))
    }

    @Test("Containment test matches a circle")
    func circleContainment() {
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))

        #expect(boundary.contains(SIMD2(0, 0)))
        #expect(boundary.contains(SIMD2(0.3, 0.3)))
        #expect(!boundary.contains(SIMD2(0.49, 0.49)))
        #expect(!boundary.contains(SIMD2(0.8, 0)))
    }

    @Test("Containment test handles a concave outline")
    func concaveContainment() {
        // An L shape occupying three quadrants of a unit square.
        let boundary = DioramaBoundary(vertices: [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0),
            SIMD2(0, 0), SIMD2(0, 0.5), SIMD2(-0.5, 0.5),
        ])

        #expect(boundary.contains(SIMD2(-0.25, 0.25)))
        #expect(boundary.contains(SIMD2(0.25, -0.25)))
        // The notch in the +X/+Z quadrant is outside.
        #expect(!boundary.contains(SIMD2(0.25, 0.25)))
    }

    @Test("Duplicate and repeated closing vertices are removed")
    func duplicateVerticesRemoved() {
        let boundary = DioramaBoundary(vertices: [
            SIMD2(-0.5, -0.5),
            SIMD2(-0.5, -0.5),
            SIMD2(0.5, -0.5),
            SIMD2(0.5, 0.5),
            SIMD2(-0.5, -0.5),
        ])
        #expect(boundary.vertices.count == 3)
    }

    @Test("Polygonal shape produces the requested side count")
    func polygonalSideCount() {
        let hexagon = DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(1.0, 1.0))
        #expect(hexagon.vertices.count == 6)

        let triangle = DioramaBoundary.make(
            shape: .polygonal(sides: 3, rotation: 0),
            extent: SIMD2(1.0, 1.0)
        )
        #expect(triangle.vertices.count == 3)
    }

    @Test("Outward normal points away from the interior")
    func outwardNormalDirection() {
        let boundary = DioramaBoundary.make(
            shape: .rectangular(width: 1.0, depth: 1.0),
            extent: SIMD2(1.0, 1.0)
        )

        for index in 0..<boundary.edgeCount {
            let (a, b) = boundary.edge(index)
            let normal = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)
            let midpoint = (a + b) / 2
            let probe = midpoint + SIMD2(normal.x, normal.z) * 0.01

            #expect(abs(normal.y) < 0.0001, "Wall normals must stay horizontal")
            #expect(!boundary.contains(probe), "Stepping along the normal must leave the chunk")
        }
    }
}
