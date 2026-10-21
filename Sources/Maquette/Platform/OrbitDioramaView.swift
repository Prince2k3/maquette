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
struct OrbitDioramaView<Gestures: ViewModifier>: View {
    let inputs: DioramaViewInputs
    @State private var model: OrbitDioramaModel
    @State private var annotations = OrbitAnnotationCoordinator()
    @FocusState private var sceneFocused: Bool
    private let makeGestures: (OrbitDioramaModel) -> Gestures

    @Environment(\.dioramaInputConfiguration) private var inputConfiguration
    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dioramaEffect) private var effect
    @Environment(\.globeTransitionStyle) private var globeStyle
    @Environment(\.dioramaCameraObservation) private var cameraObservationAction
    @Environment(\.dioramaNavigationAction) private var navigationAction
    @Environment(\.dioramaCameraChangeAction) private var cameraChangeAction
    @Environment(\.dioramaLoadingChangeAction) private var loadingChangeAction
    @Environment(\.dioramaARPlacement) private var arPlacement
    @Environment(\.dioramaCameraFitInsets) private var cameraFitInsets
    @Environment(\.dioramaCameraLimits) private var cameraLimits
    @Environment(\.dioramaCameraTransition) private var cameraTransition
    @Environment(\.dioramaCameraActionHost) private var readerCameraHost
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    #if os(iOS)
    @State private var arController = ARPlacementController()
    #endif

    init(
        inputs: DioramaViewInputs,
        makeGestures: @escaping (OrbitDioramaModel) -> Gestures
    ) {
        self.inputs = inputs
        self._model = State(initialValue: OrbitDioramaModel(
            configuration: inputs.configuration,
            content: inputs.content
        ))
        self.makeGestures = makeGestures
    }

    var body: some View {
        GeometryReader { geometry in
            realityContent
                .overlay { OrbitAnnotationHost(model: model, coordinator: annotations) }
                .onAppear {
                    model.viewSize = geometry.size
                    model.cameraSafeAreaInsets = geometry.safeAreaInsets
                    model.updateEntityScale()
                }
                .onChange(of: geometry.size) { _, newSize in
                    model.viewSize = newSize
                    model.cameraSafeAreaInsets = geometry.safeAreaInsets
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
        .modifier(DioramaControlsOverlay(state: model.controlState, cameraProxy: DioramaCameraProxy(host: model.cameraHost), onInsetsChange: { insets in
            model.cameraControlInsets = insets
            if model.usesAutomaticCamera { model.frameAutomaticCamera() }
        }))
        .dioramaAttribution(model.store.contentAttribution)
        .task(id: globeStyle) {
            guard let globeStyle else { return }
            await model.adoptGlobeStyle(globeStyle)
        }
        .task {
            syncInputs()
            await model.initialLoad(effect: effect)
        }
        .onDisappear { model.releaseCameraHost() }
        .onChange(of: cameraFitInsets) { _, _ in syncCameraConfiguration() }
        .onChange(of: cameraLimits) { _, _ in syncCameraConfiguration() }
        .onChange(of: cameraTransition) { _, _ in syncCameraConfiguration() }
        .onChange(of: reduceMotion) { _, _ in syncCameraConfiguration() }
        .onChange(of: readerCameraHost.map(ObjectIdentifier.init)) { _, _ in model.bindCameraHost(readerCameraHost) }
        .onChange(of: effect) { _, newEffect in
            model.store.setEffect(newEffect)
        }
        .onChange(of: inputConfiguration) { _, configuration in model.inputConfiguration = configuration.resolved }
        .onChange(of: inputs.interactionModes.rawValue) { _, _ in
            model.enabledGestures = inputs.interactionModes.gestureTypes
        }
        .onChange(of: displayScale) { _, scale in
            model.displayScale = scale
        }
        .onChange(of: routePreviewController.map(ObjectIdentifier.init)) { _, _ in
            model.routePreviewController = routePreviewController
        }
        .onChange(of: inputs.reloadKey) { _, key in
            syncInputs()
            model.applyReloadKey(key)
        }
        .onChange(of: cameraObservationAction?.id) { _, _ in
            model.cameraObservation.action = cameraObservationAction
        }
        .onChange(of: navigationAction?.id) { _, _ in
            model.navigation.action = navigationAction
        }
        .onChange(of: inputs.content) { _, content in
            model.setContent(content)
        }
        .onChange(of: inputs.groundPosition?.wrappedValue) { _, position in
            syncInputs()
            model.applyGroundPosition(position)
        }
        .onChange(of: inputs.position?.wrappedValue) { _, _ in
            model.positionBinding = inputs.position
            model.synchronizeCameraBinding()
        }
        .onChange(of: inputs.selection?.wrappedValue) { _, _ in
            model.selectionBinding = inputs.selection
            model.applySelection()
        }
        .onChange(of: model.store.loadingState) { _, state in
            model.updateCameraCapabilities()
            loadingChangeAction?.action(state)
        }
        .onChange(of: arPlacement?.wrappedValue) { _, active in
            #if os(iOS)
            Task {
                if active == true {
                    await arController.activate()
                    model.arPlacementActive = true
                } else {
                    await arController.deactivate()
                    model.arPlacementActive = false
                    model.updateEntityScale()
                }
            }
            #endif
        }
        .onChange(of: routePreviewController?.playbackState) { _, newState in
            model.cancelCameraAction()
            if model.arPlacementActive || model.transition.isShowingGlobe { return }
            RouteAnimationHelper.handlePlaybackStateChange(
                newState,
                cameraController: model.cameraController,
                routeEntity: model.store.routePreviewEntity,
                lastAnimationDate: &model.lastAnimationDate
            )
        }
    }

    /// Pushes the view's inputs and environment into the model, which has no hierarchy to read
    /// them from.
    private func syncCameraConfiguration() {
        model.cameraFitInsets = cameraFitInsets
        model.configureCamera(limits: cameraLimits, transition: cameraTransition, reduceMotion: reduceMotion)
    }

    private func syncInputs() {
        model.inputConfiguration = inputConfiguration.resolved
        model.initialCamera = inputs.initialCamera
        model.bindCameraHost(readerCameraHost)
        syncCameraConfiguration()
        model.syncNavigation(binding: inputs.groundPosition, action: navigationAction, preservesGround: inputs.preservesGround, configuration: inputs.configuration)
        model.enabledGestures = inputs.interactionModes.gestureTypes
        model.displayScale = displayScale
        model.routePreviewController = routePreviewController
        model.positionBinding = inputs.position
        model.selectionBinding = inputs.selection
        model.cameraObservation.action = cameraObservationAction
        model.cameraChangeAction = cameraChangeAction
        model.loadingChangeAction = loadingChangeAction
    }

    @ViewBuilder
    private var realityContent: some View {
        TimelineView(.animation(paused: !(model.needsAnimation || (model.arPlacementActive && !model.store.annotationRegistry.orderedRecords.isEmpty)))) { timeline in
            realityView()
                .onChange(of: timeline.date) { _, newDate in
                    model.advanceAnimation(at: newDate)
                    annotations.requestLayout(model)
                }
        }
    }

    private func realityView() -> some View {
        RealityView { content in
            installPicking(content)
            content.add(DioramaSceneRig.makeOrbitCamera())
            content.add(DioramaSceneRig.makeSunLight())
            content.add(DioramaSceneRig.makeFillLight())

            if let entity = model.store.dioramaEntity {
                content.add(entity)
            }
        } update: { content in
            // Async meshes can finish after an otherwise idle RealityView's last frame.
            // Observe completion so they appear without waiting for the next camera gesture.
            _ = (model.store.dioramaEntity as? DioramaEntity)?.overlayRenderer.geometryBuildCount
            installPicking(content)
            if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                camera.transform = model.cameraController.cameraTransform
            }

            #if os(iOS)
            // AR placement swaps the virtual orbit camera for the device's own, and rides the
            // diorama on the plane anchor at scale 1 — `physicalSize` is real meters on a real
            // table. The standard entity management below is skipped while the anchor owns the
            // chunk; coming back, the entity falls out of the anchor and the ordinary path
            // re-adopts it at viewport scale.
            content.camera = model.arPlacementActive ? .spatialTracking : .virtual
            if model.arPlacementActive {
                if let anchor = arController.planeAnchor {
                    if anchor.parent == nil { content.add(anchor) }
                    if let drawn = content.entities.first(where: { $0.name == "Maquette" }) {
                        content.remove(drawn)
                    }
                    DioramaSceneRig.syncPlacedChunk(model.store.dioramaEntity, on: anchor)
                }
                model.applyTransitionVisibility()
                return
            }
            #endif

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
        // Use the actual viewport projection so thin lines have a point-sized tap tolerance.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                sceneFocused = true
                model.screenTap?(value.location)
            }
        )
        .focusable()
        .focused($sceneFocused)
        .onChange(of: sceneFocused) { _, focused in model.inputFocused = focused }
        .onKeyPress(phases: [.down, .repeat]) { press in
            model.keyboardInput(key: press.key, modifiers: press.modifiers) ? .handled : .ignored
        }
        .accessibilityLabel("Terrain scene")
        .accessibilityHint("Focus this terrain scene to use its configured keyboard navigation. The Keyboard shortcuts menu lists available mappings.")
        .modifier(makeGestures(model))
    }

    private func installPicking(_ context: RealityViewCameraContent) {
        annotations.install(context, model: model)
        model.screenTap = { [weak model] point in
            guard let model, let root = model.store.dioramaEntity as? DioramaEntity,
                  let sceneRay = context.ray(through: point, in: .local, to: .scene) else { return }
            let origin = root.convert(position: sceneRay.origin, from: nil)
            let end = root.convert(position: sceneRay.origin + sceneRay.direction, from: nil)
            guard let identity = root.overlayRenderer.hitTest(at: point, project: {
                context.project(point: root.convert(position: $0, to: nil), to: .local)
            }, ray: OverlayRay(origin: origin, direction: end - origin)) else { return }
            model.selectionBinding?.toggle(identity)
            model.applySelection()
        }
    }

}
#endif
