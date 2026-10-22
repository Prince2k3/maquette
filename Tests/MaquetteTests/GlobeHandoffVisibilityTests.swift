import RealityKit
import Testing
@testable import Maquette

@Suite("Stable handoff visibility") @MainActor
struct GlobeHandoffVisibilityTests {
    @Test func idleOpaqueSceneDoesNotAcquireAnOpacityComponent() {
        let entity = Entity()
        for _ in 0..<60 { GlobeHandoffConductor.applyVisibility(to: entity, opacity: 1) }
        #expect(entity.isEnabled)
        #expect(entity.components[OpacityComponent.self] == nil)
    }
    @Test func fadesAndRestoredOpacityStillApply() {
        let entity = Entity()
        for opacity in [Float(0.5), 0, 0.75, 1] {
            GlobeHandoffConductor.applyVisibility(to: entity, opacity: opacity)
            #expect(entity.isEnabled == (opacity > DioramaSceneRig.minimumVisibleOpacity))
            #expect(entity.components[OpacityComponent.self]?.opacity == opacity)
        }
    }
}
