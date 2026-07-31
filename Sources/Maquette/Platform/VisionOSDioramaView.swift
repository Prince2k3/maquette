#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS presentation of the diorama using volumetric RealityView.
///
/// No virtual camera is needed — the user physically moves around the diorama — so this view
/// carries the same interactions the orbit platforms do, expressed without one: a drag slides the
/// terrain (or steers the globe), a pinch zooms the *ground* the way a map zooms, and pinching all
/// the way out hands off to the globe. The handoff's mechanics come from the shared
/// ``GlobeHandoffConductor``; only the framing response is volumetric.
struct VisionOSDioramaView: View {
    let inputs: DioramaViewInputs

    @State private var model: VisionOSDioramaModel
    @State private var lastMagnification: CGFloat?
    @State private var dragStartOrientation: simd_quatf?

    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dioramaEffect) private var effect
    @Environment(\.globeTransitionStyle) private var globeStyle
    @Environment(\.dioramaLoadingChangeAction) private var loadingChangeAction

    private var enabledGestures: Set<DioramaGestureType> { inputs.interactionModes.gestureTypes }

    init(inputs: DioramaViewInputs) {
        self.inputs = inputs
        self._model = State(initialValue: VisionOSDioramaModel(
            configuration: inputs.configuration,
            content: inputs.content
        ))
    }

    var body: some View {
        GeometryReader3D { geometry in
            realityContent(geometry: geometry)
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
                    model.enabledGestures = enabledGestures
                    model.selectionBinding = inputs.selection
                    model.store.setEffect(effect)
                    await model.store.load()
                    model.store.applyContent(inputs.content)
                }
                // No backdrop here: a volumetric window has the user's own room behind it, which is
                // the point of the platform. `backgroundColor` is for the flat presentations.
                .onChange(of: effect) { _, newEffect in
                    model.store.setEffect(newEffect)
                }
                .onChange(of: inputs.interactionModes.rawValue) { _, _ in
                    model.enabledGestures = enabledGestures
                }
                .onChange(of: inputs.reloadKey) { _, key in
                    model.applyReloadKey(key)
                }
                .onChange(of: inputs.content) { _, content in
                    model.setContent(content)
                }
                .onChange(of: inputs.selection?.wrappedValue) { _, selected in
                    model.selectionBinding = inputs.selection
                    model.applySelection(selected)
                }
                .onChange(of: model.store.loadingState) { _, state in
                    loadingChangeAction?.action(state)
                }
                .onChange(of: routePreviewController.map(ObjectIdentifier.init)) { _, _ in
                    model.routePreviewController = routePreviewController
                }
                .onAppear {
                    model.routePreviewController = routePreviewController
                }
                .simultaneousGesture(
                    SpatialTapGesture()
                        .targetedToAnyEntity()
                        .onEnded { value in
                            model.handleTap(on: value.entity)
                        }
                )
                .gestureIf(enabledGestures.contains(.pan) || enabledGestures.contains(.rotate),
                    DragGesture()
                        .targetedToAnyEntity()
                        .onChanged { value in
                            let translation = value.convert(
                                value.translation3D, from: .local, to: .scene
                            )
                            model.applyDrag(
                                sceneTranslation: translation,
                                startOrientation: &dragStartOrientation
                            )
                        }
                        .onEnded { _ in
                            model.endDrag()
                            dragStartOrientation = nil
                        }
                )
                .gestureIf(enabledGestures.contains(.zoom),
                    MagnifyGesture()
                        .targetedToAnyEntity()
                        .onChanged { value in
                            // Per-change ratios, not absolute magnification: the old absolute form
                            // wrote the raw magnification straight into the entity's scale, which
                            // discarded the volume-fit scale and snapped the diorama to the wrong
                            // size on the first pinch of every gesture.
                            let previous = lastMagnification ?? 1
                            lastMagnification = value.magnification
                            let ratio = Float(value.magnification / previous)
                            guard ratio > 0 else { return }
                            model.applyPinch(ratio: ratio)
                        }
                        .onEnded { _ in
                            lastMagnification = nil
                        }
                )
        }
    }

    @ViewBuilder
    private func realityContent(geometry: GeometryProxy3D) -> some View {
        TimelineView(.animation(paused: !model.needsAnimation)) { timeline in
            realityView(geometry: geometry)
                .onChange(of: timeline.date) { _, newDate in
                    model.advanceAnimation(at: newDate)
                }
        }
    }

    private func realityView(geometry: GeometryProxy3D) -> some View {
        RealityView { content in
            content.add(DioramaSceneRig.makeSunLight())
        } update: { realityViewContent in
            let volumeBounds = realityViewContent.convert(
                geometry.frame(in: .local), from: .local, to: .scene
            )
            model.updateVolume(bounds: volumeBounds)

            // Matched on identity, not on the name: the store builds a *fresh* entity on every
            // load, and a relocation off the globe is a load. Asking only whether something called
            // "Maquette" is in the scene leaves the old chunk on screen forever while the new one
            // renders nowhere.
            if let entity = model.store.dioramaEntity {
                let drawn = realityViewContent.entities.first { $0.name == "Maquette" }
                if drawn !== entity {
                    if let drawn { realityViewContent.remove(drawn) }
                    realityViewContent.add(entity)
                    model.updateEntityPlacement()
                }
            } else if let drawn = realityViewContent.entities.first(where: { $0.name == "Maquette" }) {
                // A relocation nils the store's entity for the whole rebuild. Left drawn, the chunk
                // being replaced goes on rendering the old ground at whatever opacity the crossfade
                // last set.
                realityViewContent.remove(drawn)
            }

            if let globe = model.store.globe {
                let drawn = realityViewContent.entities.first { $0.name == "Globe" }
                if drawn !== globe {
                    if let drawn { realityViewContent.remove(drawn) }
                    realityViewContent.add(globe)
                    model.updateEntityPlacement()
                }
            }

            model.applyTransitionVisibility()

            // Drive 3D Tiles LOD from a documented approximation rather than a hardcoded guess.
            // A volumetric window offers no head pose — that needs an immersive space and a
            // WorldTrackingProvider — so the camera is taken as a viewer at the HIG's typical
            // viewing distance from the volume's front face, and the screen height comes from the
            // window's own geometry rather than an assumed 1080.
            if let tiles3D = (model.store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: model.approximateViewerPosition,
                    screenHeight: Float(geometry.size.height * displayScale),
                    fov: DioramaSceneRig.fieldOfViewRadians
                )
            }
        }
    }
}

/// Shared-store state and volumetric framing for the visionOS view.
@MainActor
@Observable
final class VisionOSDioramaModel {
    let store: DioramaStore
    private(set) var content: DioramaContentGroup?
    /// The handoff's shared mechanics; this model supplies the volumetric framing response.
    let handoff = GlobeHandoffConductor()

    var enabledGestures: Set<DioramaGestureType> = [.rotate, .zoom, .pan]
    var globeStyle: GlobeTransitionStyle?
    var routePreviewController: RoutePreviewController?
    /// The selection binding handed to `DioramaView`, written on marker taps.
    var selectionBinding: Binding<DioramaAnnotation.ID?>?

    /// The scale mapping diorama meters to volume meters, measured from the window's bounds.
    private(set) var fitScale: Float = 1
    /// The volume's floor, where the chunk's underside rests.
    private(set) var floorY: Float = 0
    /// The volume's smaller horizontal extent, in scene meters.
    private(set) var volumeSpan: Float = 0.8

    /// Clearance between the volume's floor and the chunk's underside.
    private static let bottomPadding: Float = 0.014

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.store = DioramaStore(configuration: configuration)
        self.content = content
    }

    var transition: GlobeTransition {
        get { handoff.transition }
        set { handoff.transition = newValue }
    }

    func reload() {
        store.reset()
        Task {
            await store.load()
            store.applyContent(content)
        }
    }

    /// Adopts a changed region/style key; see ``DioramaLiveInputs/applyReloadKey(_:store:content:afterLoad:)``.
    func applyReloadKey(_ key: DioramaViewInputs.ReloadKey) {
        DioramaLiveInputs.applyReloadKey(key, store: store, content: content) {
            // No camera to re-frame; the volume fit re-applies when the entity swaps in.
        }
    }

    /// Re-applies changed content against the substrate already in hand.
    func setContent(_ newContent: DioramaContentGroup) {
        content = newContent
        store.applyContent(newContent)
        applySelection(selectionBinding?.wrappedValue)
    }

    /// A tap landed on an entity; walk up for a marker and toggle the selection.
    func handleTap(on entity: Entity) {
        DioramaLiveInputs.handleTap(on: entity, selection: selectionBinding, store: store)
    }

    /// Reflects the selected identity onto the marker entities.
    func applySelection(_ id: DioramaAnnotation.ID?) {
        DioramaLiveInputs.applySelection(id, store: store)
    }

    func adoptGlobeStyle(_ style: GlobeTransitionStyle) async {
        globeStyle = style
        transition.style = style
        await store.loadGlobe(style: style)
    }

    /// Suppresses the loading spinner while the globe is carrying the scene; see the orbit model.
    var overlayState: DioramaLoadingState {
        if transition.isShowingGlobe, case .loading = store.loadingState { return .loaded }
        return store.loadingState
    }

    var needsAnimation: Bool {
        routePreviewController?.playbackState == .playing || transition.isAnimating
    }

    func advanceAnimation(at date: Date) {
        handoff.advance(at: date) {
            applyTransitionFraming()
            applyTransitionVisibility()
        }
        guard let controller = routePreviewController else { return }
        controller.update(at: date)
        store.routePreviewEntity?.updateProgress(controller.progress)
    }

    // MARK: - Volume framing

    /// Re-measures the fit whenever the volume's bounds arrive or change.
    func updateVolume(bounds: BoundingBox) {
        let width = bounds.max.x - bounds.min.x
        let depth = bounds.max.z - bounds.min.z
        volumeSpan = min(width, depth)
        floorY = bounds.min.y
        let diameter = store.configuration.physicalSize
        fitScale = diameter > 0 ? volumeSpan / diameter : 1
        updateEntityPlacement()
    }

    /// Applies the volume fit to the chunk and the globe.
    ///
    /// The globe's own growth comes from ``DioramaStore/setGlobeScale(_:)``, which scales the
    /// geometry about the dock so its top stays on the diorama origin. The *entity* scale here is
    /// the volumetric answer to "how big is the world on the table": at rest the globe's diameter
    /// matches the footprint the chunk had, so pinching out dissolves the diorama into a tabletop
    /// globe of the same size rather than a sphere that filled the room.
    func updateEntityPlacement() {
        if let entity = store.dioramaEntity {
            entity.scale = SIMD3<Float>(repeating: fitScale)
            entity.position.y = floorY + Self.bottomPadding
        }
        if let globe = store.globe {
            let radius = globe.radius
            let diameter = store.configuration.physicalSize
            let globeFit = radius > 0 ? (diameter * fitScale) / (2 * radius) : fitScale
            globe.scale = SIMD3<Float>(repeating: globeFit)
            // The dock keeps the sphere's top on the diorama origin, which the entity scale
            // preserves — so the globe's top sits where the chunk's origin sat, on the floor line.
            globe.position.y = floorY + Self.bottomPadding
        }
    }

    /// Where the viewer is assumed to stand, for LOD purposes: centred on the volume's front face
    /// at the HIG's typical viewing distance (~0.8 m), at the volume's mid height.
    var approximateViewerPosition: SIMD3<Float> {
        SIMD3<Float>(0, floorY + volumeSpan * 0.5, volumeSpan * 0.5 + 0.8)
    }

    // MARK: - Gestures

    /// Whether a drag should slide the terrain rather than rotate the chunk.
    var canPanTerrain: Bool {
        guard enabledGestures.contains(.pan) else { return false }
        let root = store.dioramaEntity as? DioramaEntity
        return root?.terrain?.canPan == true || root?.tiles3D?.canPan == true
    }

    /// The last drag translation, for converting a cumulative gesture into per-change deltas.
    private var lastDragTranslation: SIMD3<Float>?

    /// Routes a drag, given its cumulative translation in scene meters.
    func applyDrag(sceneTranslation: SIMD3<Float>, startOrientation: inout simd_quatf?) {
        guard !transition.isBusy else {
            lastDragTranslation = sceneTranslation
            return
        }
        let previous = lastDragTranslation ?? .zero
        let delta = sceneTranslation - previous
        lastDragTranslation = sceneTranslation

        if transition.isShowingGlobe {
            if enabledGestures.contains(.rotate) {
                steerGlobe(sceneDelta: delta)
            }
            return
        }

        if canPanTerrain {
            // Scene meters → diorama meters through the fit scale. The ground follows the hand:
            // dragging toward +X carries the terrain +X-ward, so the sampled region moves the
            // other way, which is the sign `pan(by:)` expects of its offset delta.
            guard fitScale > 0 else { return }
            store.pan(by: SIMD2(-delta.x, -delta.z) / fitScale)
        } else if enabledGestures.contains(.rotate), let entity = store.dioramaEntity {
            // Anchored to the gesture's start rather than compounded per frame, so a drag cannot
            // accelerate under its own accumulated rotation.
            let start = startOrientation ?? entity.orientation
            startOrientation = start
            let total = lastDragTranslation ?? .zero
            let angle = (total.x / max(volumeSpan, 0.01)) * .pi
            entity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)) * start
        }
    }

    func endDrag() {
        lastDragTranslation = nil
    }

    /// Spins the world under the viewer by a drag measured in scene meters.
    ///
    /// The globe is seen whole in the volume, so a drag across its rendered diameter should carry
    /// the ground about half a turn: scene meters divide by the rendered radius to give arc, and
    /// arc rides the earth's radius to ground meters. North stays -Z — the dock's convention — so
    /// away-from-viewer is northward.
    private func steerGlobe(sceneDelta: SIMD3<Float>) {
        guard let globe = store.globe else { return }
        let renderedRadius = globe.radius * globe.scale.x
        guard renderedRadius > 0 else { return }
        let metersPerSceneMeter = Turf.earthRadiusMeters / Double(renderedRadius)
        // The ground follows the hand, so the docked coordinate goes the other way.
        store.steerGlobe(
            east: -Double(sceneDelta.x) * metersPerSceneMeter,
            north: Double(sceneDelta.z) * metersPerSceneMeter
        )
    }

    // MARK: - Zooming

    /// Routes a pinch ratio: the ground widens while it can, then the globe takes over.
    ///
    /// A ratio above 1 is fingers spreading — zoom in, less ground. The ratio converts to the same
    /// octave currency the orbit platforms calibrate against, so the ladder from a valley to the
    /// globe is the same length on every platform.
    func applyPinch(ratio: Float) {
        guard !transition.isBusy else { return }
        let delta = log2(ratio) * Self.pinchOctaveScale

        if transition.isShowingGlobe {
            absorb(delta)
            return
        }
        guard store.canZoomGround else {
            // A fixed diorama has no map to widen and no orbit camera to dolly; a zoom-out hands
            // straight to the globe when one is on offer, and otherwise has nowhere to go.
            if delta < 0, globeStyle != nil, store.globe != nil {
                absorb(delta)
            }
            return
        }

        store.zoomGround(by: exp2(-delta * DioramaSceneRig.groundZoomOctaves))

        if delta < 0, !chunkHasZoomRoom, globeStyle != nil, store.globe != nil {
            absorb(delta)
        }
    }

    /// How much zoom delta a doubling of pinch ratio is worth, matched to the iOS pinch so a full
    /// spread covers about the same share of the ground-zoom ladder on both platforms.
    private static let pinchOctaveScale: Float = 25

    private var chunkHasZoomRoom: Bool {
        guard store.canZoomGround else { return false }
        return store.groundScale < store.groundScaleLimits.upperBound * 0.999
    }

    private func absorb(_ delta: Float) {
        // The conductor's state machine wants the orbit camera's entry framing; a volume has no
        // camera, so nominal values stand in. They only seed the departure arithmetic — the
        // volumetric framing below never reads them back.
        let absorption = transition.absorb(
            zoomDelta: delta,
            cameraDistance: 1.0,
            cameraElevation: .pi / 2,
            chunkHasRoom: chunkHasZoomRoom
        )
        guard absorption.consumed else { return }
        // Relocation before framing, same ordering as the orbit platforms; see the conductor.
        if absorption.committedReturn {
            handoff.relocate(store: store, content: content) {
                // No camera to re-aim; the volume fit re-applies when the entity swaps in.
            } applyFrames: { [weak self] in
                self?.applyTransitionFraming()
                self?.applyTransitionVisibility()
            }
        }
        applyTransitionFraming()
    }

    /// The volumetric framing response: the globe grows out of the chunk about the dock.
    func applyTransitionFraming() {
        store.setGlobeScale(transition.globeScale)
        updateEntityPlacement()
        // The dock may only move while nothing is looking; progress 0 is that moment.
        if transition.progress <= 0 {
            store.dockGlobe()
        }
    }

    func applyTransitionVisibility() {
        handoff.applyVisibility(store: store)
    }
}
#endif
