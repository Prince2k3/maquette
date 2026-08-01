#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS presentation of the diorama using volumetric RealityView.
///
/// No virtual camera is needed — the user physically moves around the diorama — so this view
/// carries the same interactions the orbit platforms do, expressed without one: a drag slides the
/// terrain (or steers the globe), a pinch zooms the *ground* the way a map zooms, and zooming all
/// the way out — hands pinching together — hands off to the globe. The handoff's mechanics come
/// from the shared ``GlobeHandoffConductor``; only the framing response is volumetric.
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
                .dioramaAttribution(model.store.tilesAttribution)
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
                .simultaneousGestureIf(enabledGestures.contains(.pan) || enabledGestures.contains(.rotate),
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
                .simultaneousGestureIf(enabledGestures.contains(.zoom),
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
            // The stages are added once and never replaced; what the store hands back goes
            // *under* them. See `VisionOSDioramaModel.syncScene()`.
            content.add(model.chunkStage)
            content.add(model.globeStage)
        } update: { realityViewContent in
            let volumeBounds = realityViewContent.convert(
                geometry.frame(in: .local), from: .local, to: .scene
            )
            model.updateVolume(bounds: volumeBounds)
            model.syncScene()
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

    /// The chunk's holder in the volume, carrying the fit from diorama metres to volume metres.
    ///
    /// The store's entities are transformed in *diorama* space — the dock's placement of the globe
    /// is the strict case — so the volumetric fit lives on a parent instead of being written over
    /// them. See ``updateEntityPlacement()``.
    let chunkStage = Entity()
    /// The globe's holder in the volume. Separate from the chunk's because the two carry different
    /// fits: the chunk's is diorama metres, the globe's is its own radius scaled to that footprint.
    let globeStage = Entity()

    /// The scale mapping diorama meters to volume meters, measured from the window's bounds.
    private(set) var fitScale: Float = 1
    /// The middle of the volume, in scene meters.
    private(set) var volumeCenter: SIMD3<Float> = .zero
    /// The volume's own extents along each axis, in scene meters.
    private(set) var volumeExtents = SIMD3<Float>(repeating: 0.8)

    /// The chunk's bounding box in diorama metres, frozen when the entity is parented.
    ///
    /// Frozen rather than re-measured, for the reason the elevation baseline and the wall texture's
    /// vertical reference are: a pan changes the relief under the outline, and a framing that
    /// tracked it would slide the whole chunk around the window as the ground moved.
    private var chunkBounds: BoundingBox?

    /// The share of the window the diorama is allowed to fill, leaving a little glass around it.
    private static let volumeInset: Float = 0.92

    /// The smallest of the volume's axes — the reach a gesture is measured against.
    var volumeSpan: Float { volumeExtents.min() }

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
    ///
    /// **There is deliberately no volume-versus-window branch.** A plain window was assumed to be a
    /// flat face here, and measured it is not: this view's own bounds in a plain `WindowGroup` come
    /// back **0.941 × 0.529 × 0.397 m**, which is 40 cm of depth — deeper than any threshold that
    /// could tell it apart from a volume, and enough for a chunk fitted to `min(width, height)` to
    /// stand half out of the glass. One rule that respects every axis holds in both scenes.
    /// **Only the width and height of that box say where its middle is.** The converted rect comes
    /// back recentred on the scene origin across x and y — both centres measure 0 — but its z is
    /// still counted from the near plane, so its z *centre* lands a full depth in front of the
    /// window rather than on it. Centring the diorama there hangs the whole solid 21–58 cm out
    /// towards the viewer, where perspective magnifies it about 1.7× and it spills past the glass it
    /// measured as fitting: the chunk drew 415 px across a 640 px window plate where its own scale
    /// predicted 239. Measured in a plain `WindowGroup`, world bounds `z 0.2144…0.5797` against a
    /// volume depth of 0.3971. So the depth is taken from the box and the plane is taken from the
    /// scene origin, which is the window's own centre — the same convention x and y already report.
    func updateVolume(bounds: BoundingBox) {
        let extents = bounds.max - bounds.min
        guard extents.min().isFinite, extents.min() > 0 else { return }
        volumeExtents = extents
        let center = (bounds.min + bounds.max) / 2
        volumeCenter = SIMD3<Float>(center.x, center.y, 0)
        refreshFit()
    }

    /// Rescales the diorama so its whole solid, pitched as it rests, fits the room it is given.
    ///
    /// **The solid is fitted, not the footprint.** ``DioramaConfiguration/physicalSize`` describes
    /// the outline the chunk was cut to and says nothing about the earth mass hanging under it or
    /// the peaks standing on it, so a footprint that fits says little about whether the object does
    /// — and once the stage is pitched, the chunk's own depth leans into the vertical axis as well.
    /// Fitting the rotated bounding box against all three of the volume's axes is the only rule that
    /// cannot be overrun, and it costs nothing: the box is frozen at parent time and the pitch is a
    /// quaternion.
    ///
    /// The fit is measured at the **resting** pitch even while the handoff is easing that pitch
    /// towards the pole, so a departure cannot resize the chunk on its way out. Rotating further
    /// only trades the chunk's height for its depth, both of which the resting fit already covered.
    ///
    /// **The width and height are fitted as the viewer sees them, not as they measure.** A window's
    /// bounds are a box in scene metres and the scene is drawn in perspective, so the half of a
    /// pitched chunk that leans toward the viewer subtends more of the glass than its own extent —
    /// and a fit that only measured the box lets that half overrun the window, where it is silently
    /// clipped against the frame. The correction is a closed form rather than a fudge: at the near
    /// face the object is `D / (D - nearZ · s)` times its measured size, so requiring
    /// `s · e · D / (D − n · s) ≤ limit` solves to the expression below, which reduces to the plain
    /// ratio for a chunk lying flat. The depth axis is deliberately excluded — it must fit the
    /// volume in metres, and its apparent size is not what runs out.
    private func refreshFit() {
        let box = pitchedChunkBounds(pitch: Self.restingPitch)
        let extents = box.extents
        // The viewer's distance to the middle of the window; see `approximateViewerPosition`.
        let viewingDistance = volumeExtents.z * 0.5 + Self.assumedViewingDistance
        let near = max(box.max.z, 0)
        var scale = Float.greatestFiniteMagnitude
        for axis in 0..<3 where extents[axis] > 0 {
            let limit = volumeExtents[axis] * Self.volumeInset
            let axisScale = axis == 2
                ? limit / extents[axis]
                : limit * viewingDistance / (extents[axis] * viewingDistance + limit * near)
            scale = min(scale, axisScale)
        }
        guard scale.isFinite, scale > 0 else { return }
        fitScale = scale
        updateEntityPlacement()
    }

    /// How far the viewer is assumed to stand from the window's front face, per the HIG's typical
    /// viewing distance. An approximation on purpose: a volumetric window offers no head pose —
    /// that needs an immersive space and a `WorldTrackingProvider`.
    private static let assumedViewingDistance: Float = 0.8

    /// The chunk's bounding box after the stage's pitch, in diorama metres.
    ///
    /// Computed from the eight corners rather than by trigonometry on the extents, so it stays right
    /// for a box that is not centred on the origin — which the chunk's never is, since diorama
    /// Y = 0 is the lowest terrain and the earth mass hangs below it.
    private func pitchedChunkBounds(pitch: Float) -> BoundingBox {
        let footprint = max(store.configuration.physicalSize, 0.01)
        let local = chunkBounds ?? BoundingBox(
            min: SIMD3<Float>(-footprint / 2, -footprint / 4, -footprint / 2),
            max: SIMD3<Float>(footprint / 2, footprint / 4, footprint / 2)
        )
        let rotation = Self.pitchRotation(pitch)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in 0..<8 {
            let point = rotation.act(SIMD3<Float>(
                corner & 1 == 0 ? local.min.x : local.max.x,
                corner & 2 == 0 ? local.min.y : local.max.y,
                corner & 4 == 0 ? local.min.z : local.max.z
            ))
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return BoundingBox(min: low, max: high)
    }

    /// The pitch, as a rotation that tips the diorama's top face towards the viewer.
    private static func pitchRotation(_ pitch: Float) -> simd_quatf {
        simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// The angle the diorama rests at, shared with the orbit platforms' camera. See
    /// ``DioramaSceneRig/restingElevation``.
    private static let restingPitch = DioramaSceneRig.restingElevation

    /// The pitch in force right now: the resting angle, eased towards the pole by a handoff.
    ///
    /// This is the volumetric statement of what the orbit platforms do with their camera — the
    /// transition eases the viewing elevation to exactly π/2 so that "the point facing the viewer",
    /// "the tangent point" and "where the chunk is" become the same place, which is the only camera
    /// the dock's geometry is correct from (``GlobeDock/center`` puts the docked coordinate at the
    /// sphere's topmost point). A window's viewer cannot be moved overhead, so the world is turned
    /// under them instead, and ``GlobeTransition/cameraElevation()`` supplies exactly the same eased
    /// angle either way. Left un-pitched, the globe would arrive with the coordinate the user
    /// steered to — and the one a return relocates onto — sitting on top of the sphere, out of
    /// sight, while they aimed at its equator.
    var stagePitch: Float {
        transition.cameraElevation() ?? Self.restingPitch
    }

    /// Applies the volume fit to the chunk and the globe.
    ///
    /// **The fit goes on the stages, never on what the store hands back.** ``DioramaStore`` owns the
    /// globe's transform outright — ``DioramaStore/setGlobeScale(_:)`` and the dock both assign
    /// `globe.transform` wholesale from ``GlobeDock/matrix(scale:)`` — so a view that also writes
    /// `globe.scale` and `globe.position` onto the same entity overwrites both of them every frame.
    /// That is what "the globe transition doesn't work" was: the growth 0 → 1 the transition drives
    /// through `setGlobeScale` was replaced by a constant fit, and the dock's `radius · scale`
    /// lowering — the thing that keeps the sphere's *topmost point* on the diorama origin rather
    /// than its centre — was replaced by the floor line, so the world arrived a full radius out of
    /// place with the chunk buried inside it. A stage in between leaves diorama space to the store.
    ///
    /// The stage scale is the volumetric answer to "how big is the world on the table": the globe is
    /// framed to the same share of the window the chunk was, so zooming out dissolves the diorama
    /// into a tabletop globe of comparable size rather than a sphere that filled the room.
    func updateEntityPlacement() {
        let rotation = Self.pitchRotation(stagePitch)

        // The volumetric statement of the orbit camera's retreat. On iOS and macOS the departure
        // pulls the camera from its entry distance out to the globe's framing distance, so the
        // chunk visibly *shrinks into its place on the world* as the globe grows around it; a
        // window has no camera to pull back, and a chunk that only fades at full size reads as a
        // pale ring hanging around a smaller globe — the two halves of the crossfade at
        // unrelated sizes. The same eased clock the camera rides is read back here as a scale:
        // `absorb` seeds the nominal entry distance 1, so `1 / cameraDistance` is exactly the
        // shrink the orbit platforms' projection produces, 1 at the chunk and
        // 1/`chunkRecessionDistance` at the globe.
        let recession: Float
        if let distance = transition.cameraDistance(globeDistance: Self.chunkRecessionDistance) {
            recession = 1 / max(distance, 0.01)
        } else {
            recession = 1
        }
        let chunkScale = fitScale * recession

        var chunkLift: Float = 0
        if let globe = store.globe {
            let radius = globe.radius
            let stageScale = radius > 0
                ? (volumeSpan * Self.volumeInset) / (2 * radius)
                : fitScale
            globeStage.scale = SIMD3<Float>(repeating: stageScale)
            globeStage.orientation = rotation
            // The dock hangs the sphere a radius *below* the docked point so that point lands on the
            // diorama origin, and the whole of that hangs off the pitch: cancelling it through the
            // same rotation puts the sphere's centre in the middle of the window at every angle and
            // every size. At `globeScale` 0 the cancellation is zero too, so the world grows out of
            // the chunk's own place rather than sliding into it — the volumetric reading of the
            // growth ``GlobeTransition/globeScale`` drives.
            let lift = radius * store.globeScale * stageScale
            globeStage.position = volumeCenter + rotation.act(SIMD3<Float>(0, lift, 0))
            ensureGestureTarget(on: globe, sphereRadius: radius)
            // The chunk's anchor follows the *transition's* growth, not the store's: the store's
            // scale rests at full size with the globe merely hidden, and an anchor read from it
            // would hang the chunk a whole radius above the window on an ordinary load. The two
            // agree everywhere a leg is actually playing, because the framing tick writes the
            // transition's scale into the store one line before this runs.
            chunkLift = radius * transition.globeScale * stageScale
        }

        // The *solid* is centred, not its origin. Diorama Y = 0 is the lowest terrain elevation and
        // the earth mass hangs below it to `-baseDepth`, so resting the origin on the window's middle
        // hangs most of that mass out through the bottom of the glass, over the ornament carrying the
        // controls. Centring the pitched box puts as much room under the walls as over the peaks.
        //
        // Mid-handoff the centre is the *docked point* — the sphere's topmost point, which sits at
        // the volume's centre while the globe is at zero and rides its top as it grows — so the
        // receding chunk condenses onto the patch of world it stands for instead of shrinking in
        // the middle of the window while the globe rises past it. At rest the lift is zero and
        // this is exactly the centred fit.
        chunkStage.scale = SIMD3<Float>(repeating: chunkScale)
        chunkStage.orientation = rotation
        chunkStage.position = volumeCenter + rotation.act(SIMD3<Float>(0, chunkLift, 0))
            - pitchedChunkBounds(pitch: stagePitch).center * chunkScale

        if let entity = store.dioramaEntity {
            ensureGestureTarget(on: entity)
        }
    }

    /// Puts whatever the store currently holds under the stages.
    ///
    /// Parented rather than matched by name: the store builds a *fresh* entity on every load, and a
    /// relocation off the globe is a load. Asking only whether something called "Maquette" is in the
    /// scene leaves the old chunk on screen forever while the new one renders nowhere — and with the
    /// crossfade's `OpacityComponent` still on it, that reads as a dim frozen diorama rather than a
    /// stale one. A nil entity has to be *removed* for the same reason: `relocate` nils it for the
    /// whole rebuild, and left drawn it goes on rendering the ground that was departed from.
    func syncScene() {
        if let entity = store.dioramaEntity {
            if entity.parent !== chunkStage {
                chunkStage.children.removeAll()
                chunkStage.addChild(entity)
                let bounds = entity.visualBounds(relativeTo: entity)
                if bounds.extents.min().isFinite, bounds.extents.min() > 0 {
                    chunkBounds = bounds
                }
                refreshFit()
            }
        } else if !chunkStage.children.isEmpty {
            chunkStage.children.removeAll()
        }

        if let globe = store.globe, globe.parent !== globeStage {
            globeStage.children.removeAll()
            globeStage.addChild(globe)
            updateEntityPlacement()
        }
    }

    /// Makes an entity a target for the volumetric gestures.
    ///
    /// Every visionOS gesture here is `.targetedToAnyEntity()`, and a targeted gesture only fires
    /// on entities carrying `InputTargetComponent` **and** a `CollisionComponent` — without them
    /// the drag and the pinch simply never deliver, which reads as the whole interaction set
    /// (panning, ground zoom, and with it the globe handoff) being switched off. The orbit
    /// platforms never notice because their gestures are view-space. So the diorama root gets a
    /// coarse box over its visual bounds and the globe a sphere at its own radius; gesture
    /// targeting needs nothing finer.
    ///
    /// The trade to know about: the chunk's box encloses the markers standing on it, so a tap can
    /// resolve to the box before the pin behind it and visionOS marker selection is best-effort
    /// where iOS's is exact. Selection walks up from whatever was hit, so a miss is a no-op, never
    /// a wrong pick.
    private func ensureGestureTarget(on entity: Entity, sphereRadius: Float? = nil) {
        guard entity.components[InputTargetComponent.self] == nil else { return }
        let shape: ShapeResource
        if let sphereRadius, sphereRadius > 0 {
            // The globe's collision lives in its own local space, where the mesh has its stated
            // radius; the dock transform and entity scale carry it along.
            shape = .generateSphere(radius: sphereRadius)
        } else {
            let bounds = entity.visualBounds(relativeTo: entity)
            guard bounds.extents.x.isFinite, bounds.extents.x > 0 else { return }
            shape = .generateBox(size: bounds.extents).offsetBy(translation: bounds.center)
        }
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(InputTargetComponent())
    }

    /// Where the viewer is assumed to stand, for LOD purposes: centred on the volume's front face
    /// at the HIG's typical viewing distance (~0.8 m), at the volume's mid height.
    var approximateViewerPosition: SIMD3<Float> {
        volumeCenter + SIMD3<Float>(0, 0, volumeExtents.z * 0.5 + 0.8)
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

        // **Through the stage's own orientation, never straight off the scene axes.** The diorama is
        // pitched to face the viewer, so the ground plane it is dragged across is no longer the
        // scene's — and a delta read as `(x, z)` takes only the sliver of a drag that happens to lie
        // flat. In a window seen head-on that sliver is nothing at all: `delta.z` is ≈ 0 for every
        // gesture the user can make against the glass, so the whole north/south axis of both the pan
        // and the globe steer is silently dead. The inverse rotation is exactly the old expression at
        // a pitch of zero, so nothing that was working changes.
        let ground = Self.pitchRotation(stagePitch).inverse.act(delta)

        if transition.isShowingGlobe {
            if enabledGestures.contains(.rotate) {
                steerGlobe(groundDelta: ground)
            }
            return
        }

        if canPanTerrain {
            // Scene meters → diorama meters through the fit scale. The ground follows the hand:
            // dragging toward +X carries the terrain +X-ward, so the sampled region moves the
            // other way, which is the sign `pan(by:)` expects of its offset delta.
            guard fitScale > 0 else { return }
            store.pan(by: SIMD2(-ground.x, -ground.z) / fitScale)
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

    /// Spins the world under the viewer by a drag already rotated into the stage's own frame.
    ///
    /// The globe is seen whole in the volume, so a drag across its rendered diameter should carry
    /// the ground about half a turn: scene meters divide by the rendered radius to give arc, and
    /// arc rides the earth's radius to ground meters. North stays -Z — the dock's convention — and
    /// because the handoff has pitched the stage to the pole by the time anyone can steer, that -Z
    /// is *screen up*: a north-up map, the same one the orbit platforms steer against.
    private func steerGlobe(groundDelta sceneDelta: SIMD3<Float>) {
        guard let globe = store.globe else { return }
        // Measured against the world, not the entity's own scale: the rendered size is the stage's
        // fit *and* the dock's growth scale, and reading only the latter would make a drag track the
        // finger by the fit's factor.
        let renderedRadius = globe.radius * globe.scale(relativeTo: nil).x
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
        // A fixed diorama has no map to widen, and the handoff rides the map: a chunk that cannot
        // zoom its ground never departs for the globe. With no camera in a volume to dolly either,
        // its pinch is deliberately inert.
        guard store.canZoomGround else { return }

        store.zoomGround(by: exp2(-delta * DioramaSceneRig.groundZoomOctaves))

        if delta < 0, !chunkHasZoomRoom, globeStyle != nil, store.globe != nil {
            absorb(delta)
        }
    }

    /// How much zoom delta a doubling of pinch ratio is worth, matched to the iOS pinch so a full
    /// spread covers about the same share of the ground-zoom ladder on both platforms.
    private static let pinchOctaveScale: Float = 25

    /// The globe-framing distance the chunk's recession is measured against, in units of the
    /// nominal entry distance `absorb` seeds. 4 is roughly what the orbit platforms' ratio of
    /// entry distance to globe framing distance works out to on the demo presets, so the chunk
    /// ends the departure about a quarter of its resting size — the same share of the settled
    /// globe it visibly shrinks to on iOS and macOS.
    private static let chunkRecessionDistance: Float = 4

    private var chunkHasZoomRoom: Bool {
        guard store.canZoomGround else { return false }
        return store.groundScale < store.groundScaleLimits.upperBound * 0.999
    }

    private func absorb(_ delta: Float) {
        // The entry *distance* is nominal: a volume has no camera to dolly, so nothing reads it back.
        // The entry **elevation** is not — ``GlobeTransition/cameraElevation()`` eases it to π/2
        // across the leg, and ``stagePitch`` turns that into the angle the diorama itself is turned
        // through. Seeding it with the resting pitch is what makes the departure roll the world
        // overhead over the same second the globe grows, instead of arriving already there.
        let absorption = transition.absorb(
            zoomDelta: delta,
            cameraDistance: 1.0,
            cameraElevation: Self.restingPitch,
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
