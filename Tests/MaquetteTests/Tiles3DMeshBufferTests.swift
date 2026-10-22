import RealityKit
import Testing
@testable import Maquette

@Suite("Retained tile mesh publication") @MainActor
struct Tiles3DMeshBufferTests {
    @Test func replacementPublishesOnlyCurrentGeometryAndExactBounds() throws {
        let buffer = try Tiles3DMeshBuffer(vertexCapacity: 20, indexCapacity: 30)
        let resource = buffer.resource
        for count in [9, 3, 12, 6] {
            let vertices = (0..<count).map { index in
                Tiles3DVertex(position: SIMD3(Float(index), Float(count), 0), normal: .init(0, 1, 0), uv: .zero)
            }
            let indices = (0..<count).map(UInt32.init)
            let bounds = BoundingBox(min: SIMD3(0, Float(count), 0), max: SIMD3(Float(count - 1), Float(count), 0))
            #expect(try buffer.write(vertices: vertices, indices: indices, bounds: bounds) == .rewritten)
            #expect(buffer.resource === resource)
            let mesh = try #require(resource.lowLevelMesh)
            #expect(mesh.parts.count == 1)
            #expect(mesh.parts[0].indexCount == count)
            #expect(mesh.parts[0].bounds == bounds)
            mesh.withUnsafeBytes(bufferIndex: 0) { bytes in
                let stored = bytes.bindMemory(to: Tiles3DVertex.self)
                for index in vertices.indices { #expect(stored[index].position == vertices[index].position) }
            }
            mesh.withUnsafeIndices { bytes in
                #expect(Array(bytes.bindMemory(to: UInt32.self).prefix(count)) == indices)
            }
        }
    }
}
