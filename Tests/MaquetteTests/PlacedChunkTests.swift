import RealityKit
import Testing
@testable import Maquette

@Suite("Placed chunk replacement")
@MainActor
struct PlacedChunkTests {
    @Test("Reload replaces anchored ground while retaining placement and unrelated content")
    func replaceGround() {
        let anchor = Entity()
        anchor.position = SIMD3<Float>(1, 2, 3)
        let accessory = Entity()
        anchor.addChild(accessory)
        let old = Entity()
        old.name = "Maquette"
        DioramaSceneRig.syncPlacedChunk(old, on: anchor)
        let replacement = Entity()
        replacement.name = "Maquette"
        replacement.position = SIMD3<Float>(4, 5, 6)
        replacement.scale = SIMD3<Float>(repeating: 2)
        DioramaSceneRig.syncPlacedChunk(replacement, on: anchor)
        #expect(old.parent == nil)
        #expect(replacement.parent === anchor)
        #expect(accessory.parent === anchor)
        #expect(anchor.children.count == 2)
        #expect(anchor.position == SIMD3<Float>(1, 2, 3))
        #expect(replacement.position == .zero)
        #expect(replacement.scale == .one)
        DioramaSceneRig.syncPlacedChunk(replacement, on: anchor)
        #expect(anchor.children.count == 2)
        DioramaSceneRig.syncPlacedChunk(nil, on: anchor)
        #expect(replacement.parent == nil)
        #expect(accessory.parent === anchor)
    }
}
