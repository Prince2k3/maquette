import RealityKit
import SwiftUI

/// The one statement of the scene's camera and lighting, shared by every platform view.
///
/// The rig used to be written out three times — iOS, macOS, and the sun light a third time on
/// visionOS — and the field of view was spelled four different ways across those files (`60`
/// degrees on the camera, `60 * .pi / 180` at the LOD update, `30 * .pi / 180` as a half-angle).
/// Change the camera here and every consumer moves together; change it anywhere else and three of
/// the four spellings silently go stale.
enum DioramaSceneRig {
    /// Replaces the chunk while retaining the placement anchor and unrelated children.
    @MainActor
    static func syncPlacedChunk(_ entity: Entity?, on parent: Entity) {
        for child in Array(parent.children) where child.name == "Maquette" && child !== entity {
            child.removeFromParent()
        }
        guard let entity, entity.parent !== parent else { return }
        entity.removeFromParent()
        parent.addChild(entity)
        entity.position = .zero
        entity.scale = .one
    }

    /// The orbit camera's full field of view, in degrees. The one number the spellings derive from.
    static let fieldOfViewDegrees: Float = 60

    /// The full field of view in radians, as the 3D Tiles LOD update wants it.
    static let fieldOfViewRadians: Float = fieldOfViewDegrees * .pi / 180

    /// Half the field of view in radians, as the globe-framing arithmetic wants it.
    static let halfFieldOfView: Float = fieldOfViewRadians / 2

    /// The elevation the diorama is first seen from, in radians.
    ///
    /// **On the orbit platforms this places the camera; on visionOS it pitches the diorama**, because
    /// there is no camera in a window to place. The two are the same framing stated from opposite
    /// ends, and the visionOS half is not cosmetic: a window hangs vertically in front of the viewer,
    /// so a chunk left flat is seen exactly edge-on — the strata wall filling the glass with none of
    /// the terrain that wall is holding up visible at all. Pitching the stage by the angle the other
    /// platforms put their camera at opens every platform on the same three-quarter view.
    static let restingElevation: Float = .pi / 4

    /// Below this opacity an entity is disabled outright rather than rendered invisibly.
    static let minimumVisibleOpacity: Float = 0.001

    /// Doublings of ground coverage per unit of zoom delta.
    ///
    /// Zoom is multiplicative — a step has to *scale* the ground rather than add to it, or the same
    /// pinch crawls when the chunk is a city and leaps when it is a continent.
    ///
    /// **Calibrate it against the whole ladder, and measure the ladder rather than deriving it.** A
    /// pinch's own quantity is ``MultitouchDragTracker``'s *spread*, which is the mean distance from
    /// the touches' midpoint — half the separation between two fingers, not the separation. So a
    /// full-width pinch on a 402 pt screen is about 170 pt of spread and not 340, and a rate that
    /// reads right per point is out by two over the gesture. It was: at `1/45` this gave
    /// `170 · 0.3 / 45` ≈ **one doubling per full-width pinch**, against the eight doublings
    /// ``DioramaStore/groundScaleLimits`` spans from a chunk loaded at z12 down to
    /// ``DioramaStore/worldTileZoom``. Measured on device that was **nine full-width pinches** to
    /// reach the globe at all — a handoff most people would never find, and nobody who found it
    /// would use twice.
    ///
    /// At 0.08 the same pinch is about **four doublings**, which puts the run from a valley to the
    /// globe at two or three of them, and the return at the same: ``DioramaStore/relocate(to:)``
    /// hands the rebuilt chunk back at the scale it departed from, so the way home is the way out
    /// reversed. The same rate serves the macOS scroll and pinch — a zoom that had to be repeated
    /// nine times is no better with a trackpad than with two fingers.
    static let groundZoomOctaves: Float = 0.08

    /// Creates the orbit camera.
    @MainActor
    static func makeOrbitCamera() -> PerspectiveCamera {
        let camera = PerspectiveCamera()
        camera.name = "OrbitCamera"
        camera.camera.fieldOfViewInDegrees = fieldOfViewDegrees
        // Vertical is RealityKit's default, stated so it is configuration rather than folklore:
        // the framing arithmetic (`globeDistanceInView`, `terrainPanDelta`) and the whole
        // window-size-invariance story assume the 60° is the *vertical* angle, with the horizontal
        // derived from aspect. A window widened at fixed height must reveal more, never crop.
        camera.camera.fieldOfViewOrientation = .vertical
        return camera
    }

    /// Creates the key light: the sun, from high in the northwest, with shadows.
    @MainActor
    static func makeSunLight() -> DirectionalLight {
        let sunLight = DirectionalLight()
        sunLight.name = "SunLight"
        sunLight.light.intensity = 1200
        sunLight.light.color = .white
        sunLight.shadow = .init()
        sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
        return sunLight
    }

    /// Creates the fill light that keeps the shadowed side legible.
    @MainActor
    static func makeFillLight() -> PointLight {
        let fillLight = PointLight()
        fillLight.name = "FillLight"
        fillLight.light.intensity = 300
        fillLight.light.color = .white
        fillLight.light.attenuationRadius = 5.0
        fillLight.position = SIMD3<Float>(0.5, 0.8, 0.5)
        return fillLight
    }
}
