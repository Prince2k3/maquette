import RealityKit
import Testing
import simd
@testable import Maquette

@Suite("Photorealistic shallow base and fixed footprint")
struct PhotorealShallowBaseTests {
    @Test func unevenParallelQuotasRecoverTheValidAggregateWall() async throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0), (c, d) = prism.boundary.edge(1)
        let crossing = [
            Tiles3DCutEdge(a: SIMD3(a.x, 2, a.y), b: SIMD3(b.x, 2.08, b.y), boundaryEdge: 0),
            Tiles3DCutEdge(a: SIMD3(a.x, 2.08, a.y), b: SIMD3(b.x, 2, b.y), boundaryEdge: 0)
        ]
        // Non-emitting cuts consume input quota without consuming output. The meaningful edge
        // needs more than its proportional eight triangles, but fits the aggregate budget.
        let empty = Tiles3DCutEdge(a: SIMD3(c.x, -10, c.y), b: SIMD3(d.x, -10, d.y), boundaryEdge: 1)
        let edges = crossing + Array(repeating: empty, count: 12_498)
        let serial = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        #expect(serial.mesh.indices.count / 3 > 8)
        let parallel = try #require(try await Tiles3DShallowClosure.buildParallel(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        #expect(parallel.mesh.indices == serial.mesh.indices)
        #expect(parallel.mesh.vertices.map(\.position) == serial.mesh.vertices.map(\.position))
        #expect(parallel.mesh.vertices.map(\.uv) == serial.mesh.vertices.map(\.uv))
        #expect(parallel.parts.map(\.materialIndex) == serial.parts.map(\.materialIndex))
    }

    @Test func parallelCoveragePreservesEveryTriangleMaterialNormalAndUV() async throws {
        let prism = BoundaryPrism(boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), scale: 1)
        var edges: [Tiles3DCutEdge] = []
        for edge in prism.boundary.vertices.indices {
            let (a, b) = prism.boundary.edge(edge)
            for segment in 0..<8 {
                let left = a + (b - a) * (Float(segment) / 8)
                let right = a + (b - a) * (Float(segment + 1) / 8)
                for layer in 0..<2 {
                    let y = Float(0.3) + Float(layer) * 0.003
                    edges.append(.init(a: SIMD3(left.x, y, left.y), b: SIMD3(right.x, y + 0.001, right.y), boundaryEdge: edge))
                }
            }
        }
        let serial = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        let parallel = try #require(try await Tiles3DShallowClosure.buildParallel(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        func triangles(_ geometry: Tiles3DShallowClosure.Geometry) -> [String] {
            geometry.parts.flatMap { part in
                let first = part.indexOffset / MemoryLayout<UInt32>.stride
                return stride(from: first, to: first + part.indexCount, by: 3).map { index in
                    let vertices = (0..<3).map { j -> String in
                        let v = geometry.mesh.vertices[Int(geometry.mesh.indices[index + j])]
                        return "\(v.position)|\(v.nx),\(v.ny),\(v.nz)|\(v.uv)"
                    }
                    // Cyclic rotations preserve winding; a reversed triangle cannot match.
                    let rotations = (0..<3).map { j in (0..<3).map { vertices[(j + $0) % 3] }.joined(separator: ";") }
                    return "\(part.materialIndex):\(rotations.min()!)"
                }
            }.sorted()
        }
        #expect(triangles(serial) == triangles(parallel))
        #expect(serial.mesh.bounds == parallel.mesh.bounds)
        #expect(serial.parts.map(\.bounds) == parallel.parts.map(\.bounds))
        #expect(serial.parts.map(\.materialIndex) == parallel.parts.map(\.materialIndex))
    }

    @Test("A cut edge on high ground cannot produce a tall earth wall")
    func highGroundHasShallowWalls() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let edges = [Tiles3DCutEdge(a: SIMD3(a.x, 10, a.y), b: SIMD3(b.x, 20, b.y), boundaryEdge: 0)]
        let geometry = try #require(Tiles3DCutWall.buildGeometry(edges: edges, floorY: -100, prism: prism))
        let thickness = stride(from: 0, to: geometry.vertices.count, by: 2).map {
            geometry.vertices[$0].py - geometry.vertices[$0 + 1].py
        }
        #expect(thickness.allSatisfy { $0 >= 0 && $0 <= 0.10001 })
        #expect(geometry.vertices[0].py == 10)
        #expect(geometry.vertices[2].py == 20)
    }

    @Test("Circle, hexagon and square cutouts stay fixed under repeated pans")
    func selectedFootprintNeverFollowsTheTerrain() throws {
        let scale: Float = 0.001
        for shape in [DioramaShape.circular, .hexagonal, .rectangular(width: 0.8, depth: 0.8)] {
            let fixed = DioramaBoundary.make(shape: shape, extent: SIMD2(repeating: 0.8))
            let expectedArea = PolygonClipping.area(fixed.vertices)
            for offset in [SIMD2<Float>.zero, SIMD2(0.12, -0.08), SIMD2(-0.11, 0.14), .zero] {
                let moved = DioramaBoundary(vertices: fixed.vertices.map { $0 + offset })
                let prism = BoundaryPrism(boundary: moved, scale: scale)
                var descriptor = MeshDescriptor(name: "Sloping ground")
                descriptor.positions = .init([SIMD3(-2000, -100, -2000), SIMD3(-2000, 300, 2000),
                    SIMD3(2000, 900, 2000), SIMD3(2000, 500, -2000)])
                descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])
                let clipped = Tiles3DClipper.clip(descriptors: [descriptor], placement: matrix_identity_float4x4, to: prism)
                #expect(!clipped.isEmpty)
                var area: Float = 0
                for index in stride(from: 0, to: clipped.indices.count, by: 3) {
                    let a = clipped.vertices[Int(clipped.indices[index])].position
                    let b = clipped.vertices[Int(clipped.indices[index + 1])].position
                    let c = clipped.vertices[Int(clipped.indices[index + 2])].position
                    area += abs(simd_cross(b - a, c - a).y) * scale * scale / 2
                }
                #expect(abs(area - expectedArea) < 1e-4)
                for cut in clipped.cutEdges {
                    for endpoint in [cut.a, cut.b] {
                        let physical = SIMD2(endpoint.x, endpoint.z) * scale - offset
                        #expect(fixed.distance(from: physical, toEdge: cut.boundaryEdge) < 1e-4)
                    }
                }
            }
        }
    }
    @Test("Earth and an oversized tray share the same ten-percent ceiling")
    func trayCannotEvadeTheThicknessBudget() {
        for extent in [Float(0.2), 0.8, 2] {
            let boundary = DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(repeating: extent))
            for requested in [Float(-1), 0, 0.025, 100, .infinity, .nan] {
                let layout = Tiles3DShallowBaseLayout(boundary: boundary,
                    base: .tray(color: .gray, thickness: requested, inset: 0))
                #expect(layout.earthDepth.isFinite && layout.trayThickness.isFinite)
                #expect(layout.earthDepth >= layout.maximumThickness / 2)
                #expect(layout.trayThickness >= 0)
                #expect(abs(layout.earthDepth + layout.trayThickness - layout.maximumThickness) < 1e-6)
            }
        }
    }

    @Test("Undersides share resources and move vertically even with rotated source placement")
    @MainActor
    func undersideTracksMeshAndPlacementWithoutMovingTheFootprint() throws {
        let tile = ModelEntity(mesh: .generateBox(size: 1), materials: [DioramaMaterials.unlitMaterial(color: .white)])
        tile.transform = Transform(scale: SIMD3(2, 3, 4),
            rotation: simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3(1, 2, 3))), translation: SIMD3(100, 500, -90))
        let parent = Entity(); parent.addChild(tile)
        let underside = Tiles3DShallowUnderside(depth: 0.1, color: .gray)
        underside.install(on: tile)
        let bottom = try #require(tile.children.first as? ModelEntity)
        #expect(bottom.model?.mesh === tile.model?.mesh)
        let delta = bottom.convert(position: .zero, to: parent) - tile.convert(position: .zero, to: parent)
        #expect(simd_distance(delta, SIMD3(0, -0.1, 0)) < 1e-4)
        let material = try #require(bottom.model?.materials.first as? UnlitMaterial)
        #expect(material.faceCulling == .front)
        let next = MeshResource.generateBox(size: 2)
        tile.model?.mesh = next
        underside.install(on: tile)
        #expect(tile.children.count == 1)
        #expect(bottom.model?.mesh === next)
        tile.model = nil
        underside.install(on: tile)
        #expect(tile.children.isEmpty)
    }

    @Test("Earth and tray bands form one shallow rim with byte-correct material ranges")
    func closureBandsMeetTheSharedUnderside() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let edges = [Tiles3DCutEdge(a: SIMD3(a.x, 2, a.y), b: SIMD3(b.x, 4, b.y), boundaryEdge: 0)]
        let result = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        #expect(result.parts.count == 2)
        #expect(result.parts[0].materialIndex == 0 && result.parts[1].materialIndex == 1)
        #expect(result.parts[1].indexOffset == result.parts[0].indexCount * MemoryLayout<UInt32>.stride)
        #expect(abs(result.mesh.vertices[1].py - result.mesh.vertices[4].py) < 1e-6)
        #expect(abs(result.mesh.vertices[3].py - result.mesh.vertices[6].py) < 1e-6)
        #expect(abs(result.mesh.vertices[0].py - result.mesh.vertices[5].py - 0.1) < 1e-6)
        #expect(abs(result.mesh.vertices[2].py - result.mesh.vertices[7].py - 0.1) < 1e-6)
    }

    @Test("A tray without earth walls still uses the lower material band")
    func wallNonePreservesTheRequestedTrayBand() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let edges = [Tiles3DCutEdge(a: SIMD3(a.x, 2, a.y), b: SIMD3(b.x, 2, b.y), boundaryEdge: 0)]
        let result = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: false))
        #expect(result.parts.count == 1 && result.parts[0].materialIndex == 1)
        #expect(result.parts[0].indexOffset == 0)
        #expect(result.mesh.vertices.count == 4)
        #expect(abs(result.mesh.vertices[0].py - 1.94) < 1e-6)
        #expect(abs(result.mesh.vertices[1].py - 1.9) < 1e-6)
    }

    @Test("Overlapping photogrammetry cuts have a single wall face per covered point")
    func overlappingCutsDoNotFightForDepth() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let edges = [Float(2), 2.025, 2.025].map { height in
            Tiles3DCutEdge(a: SIMD3(a.x, height, a.y), b: SIMD3(b.x, height, b.y), boundaryEdge: 0)
        }
        let result = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        var area: Float = 0
        for i in stride(from: 0, to: result.mesh.indices.count, by: 3) {
            let points = (0..<3).map { result.mesh.vertices[Int(result.mesh.indices[i + $0])].position }
            area += simd_length(simd_cross(points[1] - points[0], points[2] - points[0])) / 2
        }
        // Three source skirts overlap; their union is a single 0.125 m high strip.
        #expect(abs(area - 0.125 * simd_distance(a, b)) < 1e-5)
    }

    @Test("Crossing cut layers retain their union without coplanar overlaps or inward triangles")
    func crossingLayersHaveUniqueCoverage() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let normal = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)
        let edges = [(Float(2), Float(2.08)), (Float(2.08), Float(2))].map { heights in
            Tiles3DCutEdge(a: SIMD3(a.x, heights.0, a.y), b: SIMD3(b.x, heights.1, b.y), boundaryEdge: 0)
        }
        let result = try #require(try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
            earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        let direction = simd_normalize(b - a)
        var triangles: [[SIMD2<Double>]] = []
        for i in stride(from: 0, to: result.mesh.indices.count, by: 3) {
            let vertices = (0..<3).map { result.mesh.vertices[Int(result.mesh.indices[i + $0])].position }
            let cross = simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0])
            #expect(simd_dot(cross, normal) >= -1e-7)
            triangles.append(vertices.map { SIMD2(Double(simd_dot(SIMD2($0.x, $0.z) - a, direction)), Double($0.y)) })
        }
        // Jitter keeps probes away from artificial slab cuts and triangulation diagonals.
        for ix in 0..<37 {
            let x = (Double(ix) + 0.317) / 37
            for iy in 0..<31 {
                let y = 1.88 + (Double(iy) + 0.619) / 31 * 0.22
                let topA = 2 + 0.08 * x, topB = 2.08 - 0.08 * x
                let expected = (y > topA - 0.1 && y < topA) || (y > topB - 0.1 && y < topB)
                let point = SIMD2(x, y)
                let covered = triangles.filter { triangle in
                    let sides = (0..<3).map { j in OverlayMath.cross(triangle[(j + 1) % 3] - triangle[j], point - triangle[j]) }
                    return sides.allSatisfy { $0 > 1e-10 } || sides.allSatisfy { $0 < -1e-10 }
                }.count
                #expect(covered == (expected ? 1 : 0))
            }
        }
        let reordered = try #require(try Tiles3DShallowClosure.build(edges: edges.reversed(), lowestY: 0,
            prism: prism, earthDepth: 0.06, trayDepth: 0.04, includesWalls: true))
        #expect(reordered.mesh.indices == result.mesh.indices)
        #expect(reordered.mesh.vertices.map(\.position) == result.mesh.vertices.map(\.position))
        #expect(reordered.mesh.vertices.map(\.uv) == result.mesh.vertices.map(\.uv))
    }

    @Test("Dense crossing walls respect a bounded geometry budget")
    func denseWallsCannotMonopolizeTheMainActor() {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        let edges = (0..<200).map { index in
            let t = Float(index) / 200
            return Tiles3DCutEdge(a: SIMD3(a.x, 2 + t * 0.1, a.y),
                b: SIMD3(b.x, 2.1 - t * t * 0.1, b.y), boundaryEdge: 0)
        }
        #expect(throws: OverlayGeometryError.budgetExceeded) {
            try Tiles3DShallowClosure.build(edges: edges, lowestY: 0, prism: prism,
                earthDepth: 0.06, trayDepth: 0.04, includesWalls: true)
        }
    }

    @Test func disjointBandsMatchTheGeneralUnionPath() throws {
        let prism = BoundaryPrism(boundary: .make(shape: .rectangular(width: 1, depth: 1),
            extent: SIMD2(repeating: 1)), scale: 1)
        let (a, b) = prism.boundary.edge(0)
        for walls in [true, false] {
            for height in [Float(-0.04), 0, 2] {
                let edge = Tiles3DCutEdge(a: SIMD3(a.x, height, a.y), b: SIMD3(b.x, height + 0.02, b.y), boundaryEdge: 0)
                let fast = try #require(try Tiles3DShallowClosure.build(edges: [edge], lowestY: 0, prism: prism,
                    earthDepth: 0.06, trayDepth: 0.04, includesWalls: walls))
                let general = try #require(try Tiles3DShallowClosure.build(edges: [edge, edge], lowestY: 0, prism: prism,
                    earthDepth: 0.06, trayDepth: 0.04, includesWalls: walls))
                func areas(_ geometry: Tiles3DShallowClosure.Geometry) -> [Float] {
                    geometry.parts.map { part in
                        let start = part.indexOffset / MemoryLayout<UInt32>.stride
                        return stride(from: start, to: start + part.indexCount, by: 3).reduce(Float(0)) { total, index in
                            let a = geometry.mesh.vertices[Int(geometry.mesh.indices[index])].position
                            let b = geometry.mesh.vertices[Int(geometry.mesh.indices[index + 1])].position
                            let c = geometry.mesh.vertices[Int(geometry.mesh.indices[index + 2])].position
                            return total + simd_length(simd_cross(b - a, c - a)) / 2
                        }
                    }
                }
                #expect(fast.parts.map(\.materialIndex) == general.parts.map(\.materialIndex))
                #expect(zip(areas(fast), areas(general)).allSatisfy { abs($0 - $1) < 1e-6 })
                #expect(fast.mesh.bounds == general.mesh.bounds)
            }
        }
    }

}
