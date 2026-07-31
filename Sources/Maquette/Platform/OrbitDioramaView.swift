#if os(iOS) || os(macOS)
import RealityKit
import SwiftUI

#if canImport(_RealityKit_SwiftUI)
// `RealityView` lives in the RealityKit ↔ SwiftUI *cross-import overlay*. Xcode enables
// cross-import overlays by default, so app targets never notice — but plain `swift build`
// does not, and the only SPM knob that would (`-Xfrontend -enable-cross-import-overlays`
// via `unsafeFlags`) makes the package unusable as a dependency. Naming the overlay module
// directly is the one route that keeps both `swift build` and consumers working; the
// `canImport` guard makes it degrade harmlessly for Xcode builds if the underscored module
// is ever renamed.
@preconcurrency import _RealityKit_SwiftUI
#endif

/// The shared body of the two orbit-camera platform views.
///
/// This is everything iOS and macOS used to duplicate — the scene, the loading overlay, the
/// lifecycle tasks, the animation timeline, and the RealityView make/update closures. The one
/// thing a platform supplies is its gesture adapter: a `ViewModifier` built over the model's
/// intent methods, so the input vocabulary is per-platform and its meaning is not.
///
/// The duplication this replaces was not free: two of the three divergences it had accumulated
/// were bugs (the stale-entity removal branch and the relocation clock reset existed on iOS and
/// not on macOS), which is what happens to six hundred lines maintained twice.
struct OrbitDioramaView<Gestures: ViewModifier>: View {
    @State private var model: OrbitDioramaModel
    private let makeGestures: (OrbitDioramaModel) -> Gestures

    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.enabledDioramaGestures) private var enabledGestures
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dioramaEffect) private var effect
    @Environment(\.globeTransitionStyle) private var globeStyle

    init(
        configuration: DioramaConfiguration,
        content: DioramaContentGroup?,
        makeGestures: @escaping (OrbitDioramaModel) -> Gestures
    ) {
        self._model = State(initialValue: OrbitDioramaModel(configuration: configuration, content: content))
        self.makeGestures = makeGestures
    }

    var body: some View {
        GeometryReader { geometry in
            realityContent
                .onAppear {
                    model.viewSize = geometry.size
                    model.updateEntityScale()
                }
                .onChange(of: geometry.size) { _, newSize in
                    model.viewSize = newSize
                    model.updateEntityScale()
                }
        }
        // An effect that draws its own light needs darkness behind it, or the contours are no
        // longer the brightest thing on screen.
        .background(effect.backgroundColor ?? .clear)
        .dioramaLoadingOverlay(
            state: model.overlayState,
            streamingProgress: model.store.streamingProgress
        ) {
            model.reload()
        }
        .task(id: globeStyle) {
            guard let globeStyle else { return }
            await model.adoptGlobeStyle(globeStyle)
        }
        .task {
            syncEnvironment()
            await model.initialLoad(effect: effect)
        }
        .onChange(of: effect) { _, newEffect in
            model.store.setEffect(newEffect)
        }
        .onChange(of: enabledGestures) { _, gestures in
            model.enabledGestures = gestures
        }
        .onChange(of: displayScale) { _, scale in
            model.displayScale = scale
        }
        .onChange(of: routePreviewController.map(ObjectIdentifier.init)) { _, _ in
            model.routePreviewController = routePreviewController
        }
        .onChange(of: model.store.configuration.buildings?.isVisible) { _, isVisible in
            model.store.setBuildingsVisible(isVisible ?? false)
        }
        .onChange(of: routePreviewController?.playbackState) { _, newState in
            RouteAnimationHelper.handlePlaybackStateChange(
                newState,
                cameraController: model.cameraController,
                routeEntity: model.store.routePreviewEntity,
                lastAnimationDate: &model.lastAnimationDate
            )
        }
    }

    /// Pushes the environment's values into the model, which has no hierarchy to read them from.
    private func syncEnvironment() {
        model.enabledGestures = enabledGestures
        model.displayScale = displayScale
        model.routePreviewController = routePreviewController
    }

    @ViewBuilder
    private var realityContent: some View {
        TimelineView(.animation(paused: !model.needsAnimation)) { timeline in
            realityView()
                .onChange(of: timeline.date) { _, newDate in
                    model.advanceAnimation(at: newDate)
                }
        }
    }

    private func realityView() -> some View {
        RealityView { content in
            content.add(DioramaSceneRig.makeOrbitCamera())
            content.add(DioramaSceneRig.makeSunLight())
            content.add(DioramaSceneRig.makeFillLight())

            if let entity = model.store.dioramaEntity {
                content.add(entity)
            }
        } update: { content in
            if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                camera.transform = model.cameraController.cameraTransform
            }

            // Matched on identity, not on the name: the store builds a *fresh* entity on every
            // load, and a relocation off the globe is a load. Asking only whether something called
            // "Maquette" is in the scene leaves the old chunk on screen forever while the new one
            // renders nowhere — and because the crossfade left an `OpacityComponent` behind on it,
            // it reads as a dim frozen diorama rather than as a stale one.
            if let entity = model.store.dioramaEntity {
                let drawn = content.entities.first { $0.name == "Maquette" }
                if drawn !== entity {
                    if let drawn { content.remove(drawn) }
                    content.add(entity)
                    model.updateEntityScale()
                }
            } else if let drawn = content.entities.first(where: { $0.name == "Maquette" }) {
                // A relocation nils the store's entity for the whole rebuild. Left drawn, the chunk
                // that is being replaced goes on rendering the *old* ground at whatever opacity the
                // crossfade last set — which is what made the return leg read as a stale, dim
                // diorama sitting under the globe rather than as ground being fetched.
                content.remove(drawn)
            }

            if let globe = model.store.globe {
                let drawn = content.entities.first { $0.name == "Globe" }
                if drawn !== globe {
                    if let drawn { content.remove(drawn) }
                    content.add(globe)
                    model.updateEntityScale()
                }
            }

            model.applyTransitionVisibility()

            // Drive 3D Tiles LOD updates from camera position changes. Screen-space error is
            // measured in pixels, so the view's height has to be converted out of points first —
            // passing points asks for a third of the detail on a 3× display, which reads as a
            // model that never sharpens.
            if let tiles3D = (model.store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: model.cameraController.cameraPosition,
                    screenHeight: Float(model.viewSize.height * model.displayScale),
                    fov: DioramaSceneRig.fieldOfViewRadians
                )
            }
        }
        .modifier(makeGestures(model))
    }
}
#endif
