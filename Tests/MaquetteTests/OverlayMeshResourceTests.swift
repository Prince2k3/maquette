import RealityKit
import Testing
@testable import Maquette

@MainActor
struct OverlayMeshResourceTests {
    private func geometry(vertices: Int, indices: Int) -> OverlayMesh {
        OverlayMesh(
            positions: (0..<vertices).map { .init(Float($0 % 3), Float($0 / 3), 0) },
            normals: .init(repeating: .init(0, 0, 1), count: vertices),
            uvs: .init(repeating: .zero, count: vertices),
            indices: (0..<indices).map { UInt32($0 % vertices) }
        )
    }

    @Test func growingOneBufferDoesNotShrinkTheOther() throws {
        let mesh = OverlayMeshResource()
        try mesh.update(geometry(vertices: 9, indices: 9))
        try mesh.update(geometry(vertices: 18, indices: 9))
        try mesh.update(geometry(vertices: 9, indices: 18))
        let resource = try #require(mesh.resource)
        for _ in 0..<3 {
            try mesh.update(geometry(vertices: 18, indices: 9))
            #expect(mesh.resource === resource)
            try mesh.update(geometry(vertices: 9, indices: 18))
            #expect(mesh.resource === resource)
        }
    }

    @Test func growthReserveKeepsModestExpansionInTheInitialResource() throws {
        let mesh = OverlayMeshResource()
        try mesh.update(geometry(vertices: 12, indices: 12), reserveForGrowth: true)
        let initial = try #require(mesh.resource)
        try mesh.update(geometry(vertices: 18, indices: 18), reserveForGrowth: true)
        #expect(mesh.resource === initial)
        try mesh.update(geometry(vertices: 36, indices: 36), reserveForGrowth: true)
        let expanded = try #require(mesh.resource)
        #expect(expanded !== initial)
        try mesh.update(geometry(vertices: 18, indices: 18), reserveForGrowth: true)
        #expect(mesh.resource === expanded)
    }
    @Test func failedGrowthCanRetryResourceCreation() throws {
        enum ConversionFailure: Error { case failed }
        var attempts = 0
        let mesh = OverlayMeshResource { candidate in
            attempts += 1
            if attempts == 2 { throw ConversionFailure.failed }
            return try MeshResource(from: candidate)
        }
        try mesh.update(geometry(vertices: 9, indices: 9))
        let initial = try #require(mesh.resource)
        #expect(throws: ConversionFailure.self) {
            try mesh.update(geometry(vertices: 18, indices: 18))
        }
        #expect(mesh.resource === initial)
        try mesh.update(geometry(vertices: 18, indices: 18))
        #expect(attempts == 3)
        #expect(mesh.resource !== initial)
    }

}
