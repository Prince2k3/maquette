#if os(iOS)
import SwiftUI
import RealityKit

/// iOS presentation of the diorama with embedded RealityView and touch gestures.
///
/// Uses a `CameraController` for orbit camera and touch gesture handling:
/// - Single finger drag → rotate orbit camera
/// - Pinch → zoom
/// - Two-finger pan → translate
struct IOSDioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    @State private var store: DioramaStore
    @State private var cameraController = CameraController()
    @State private var dragTracker = MultitouchDragTracker()
    @State private var viewSize: CGSize = CGSize(width: 400, height: 400)
    @State private var lastAnimationDate: Date?

    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.enabledDioramaGestures) private var enabledGestures
    @Environment(\.displayScale) private var displayScale

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.configuration = configuration
        self.content = content
        self._store = State(initialValue: DioramaStore(configuration: configuration))
    }

    var body: some View {
        GeometryReader { geometry in
            realityContent
                .onAppear {
                    viewSize = geometry.size
                    updateEntityScale()
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                    updateEntityScale()
                }
        }
        .dioramaLoadingOverlay(
            state: store.loadingState,
            streamingProgress: store.streamingProgress
        ) {
            store.reset()
            Task {
                await store.load()
                store.applyContent(content)
                frameLoadedChunk()
            }
        }
        .task {
            if let elevation = configuration.cameraElevation {
                cameraController.elevation = elevation
            }
            if let distance = configuration.cameraDistance {
                cameraController.distance = distance
            }
            await store.load()
            store.applyContent(content)
            frameLoadedChunk()
        }
        .onChange(of: routePreviewController?.playbackState) { _, newState in
            RouteAnimationHelper.handlePlaybackStateChange(
                newState,
                cameraController: cameraController,
                routeEntity: store.routePreviewEntity,
                lastAnimationDate: &lastAnimationDate
            )
        }
    }

    /// Points the orbit camera at the chunk's vertical midpoint.
    ///
    /// The chunk hangs below Y = 0 by its base depth, so orbiting the origin would frame it high.
    private func frameLoadedChunk() {
        guard let entity = store.dioramaEntity as? DioramaEntity else { return }
        cameraController.target.y = entity.verticalCenter
    }

    /// Scale applied to the diorama entity so it fills the available view.
    private var entityScale: Float {
        Float(min(viewSize.width, viewSize.height) / 400.0)
    }

    private func updateEntityScale() {
        guard let entity = store.dioramaEntity else { return }
        entity.scale = SIMD3<Float>(repeating: entityScale)
    }

    @ViewBuilder
    private var realityContent: some View {
        let needsAnimation = routePreviewController?.playbackState == .playing
            || cameraController.routeFollowPhase == .exiting
        TimelineView(.animation(paused: !needsAnimation)) { timeline in
            realityView()
                .onChange(of: timeline.date) { _, newDate in
                    advanceAnimation(at: newDate)
                }
        }
    }

    private func advanceAnimation(at date: Date) {
        guard let controller = routePreviewController else { return }
        RouteAnimationHelper.advanceAnimation(
            at: date,
            controller: controller,
            routeEntity: store.routePreviewEntity,
            cameraController: cameraController,
            lastAnimationDate: &lastAnimationDate
        )
    }

    private func realityView() -> some View {
        RealityView { content in
            let camera = PerspectiveCamera()
            camera.name = "OrbitCamera"
            camera.camera.fieldOfViewInDegrees = 60
            content.add(camera)

            let sunLight = DirectionalLight()
            sunLight.name = "SunLight"
            sunLight.light.intensity = 1200
            sunLight.light.color = .white
            sunLight.shadow = .init()
            sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
            content.add(sunLight)

            let fillLight = PointLight()
            fillLight.name = "FillLight"
            fillLight.light.intensity = 300
            fillLight.light.color = .white
            fillLight.light.attenuationRadius = 5.0
            fillLight.position = SIMD3<Float>(0.5, 0.8, 0.5)
            content.add(fillLight)

            if let entity = store.dioramaEntity {
                content.add(entity)
            }
        } update: { content in
            if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                camera.transform = cameraController.cameraTransform
            }

            if let entity = store.dioramaEntity,
               !content.entities.contains(where: { $0.name == "Maquette" }) {
                content.add(entity)
                updateEntityScale()
            }

            // Drive 3D Tiles LOD updates from camera position changes. Screen-space error is
            // measured in pixels, so the view's height has to be converted out of points first —
            // passing points asks for a third of the detail on a 3× display, which reads as a
            // model that never sharpens.
            if let tiles3D = (store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: cameraController.cameraPosition,
                    screenHeight: Float(viewSize.height * displayScale),
                    fov: 60 * .pi / 180
                )
            }
        }
        // One gesture handles everything, so pan, orbit, and zoom never contend for the same
        // touches: one finger slides the ground, two orbit the camera and pinch to zoom.
        .gesture(
            SpatialEventGesture(coordinateSpace: .local)
                .onChanged { events in
                    let locations = events.filter { $0.phase == .active }.map(\.location)
                    guard let update = dragTracker.update(with: locations) else { return }
                    apply(update)
                }
                .onEnded { _ in
                    dragTracker.reset()
                }
        )
    }

    /// Routes a multitouch update to panning, orbiting, and zooming.
    ///
    /// A single touch slides the terrain, matching how a map behaves. When the chunk cannot pan —
    /// either the caller disabled it or the configuration set no pan range — a single touch orbits
    /// instead, so a fixed diorama still responds the way it always has.
    private func apply(_ update: MultitouchDragTracker.Update) {
        let dx = Float(update.translation.width)
        let dy = Float(update.translation.height)

        if update.touchCount == 1 {
            if canPanTerrain {
                store.pan(by: cameraController.terrainPanDelta(
                    dragDeltaX: dx,
                    dragDeltaY: dy,
                    viewHeight: Float(viewSize.height),
                    entityScale: entityScale
                ))
            } else if enabledGestures.contains(.rotate) {
                cameraController.rotate(deltaX: dx, deltaY: dy)
            }
            return
        }

        if enabledGestures.contains(.rotate) {
            cameraController.rotate(deltaX: dx, deltaY: dy)
        }
        if enabledGestures.contains(.zoom), update.spreadChange != 0 {
            cameraController.zoom(delta: Float(update.spreadChange) * Self.pinchZoomScale)
        }
    }

    /// Whether a single touch should slide the terrain rather than orbit.
    private var canPanTerrain: Bool {
        enabledGestures.contains(.pan)
            && (store.dioramaEntity as? DioramaEntity)?.terrain?.canPan == true
    }

    /// Converts the change in touch spread, in points, into a zoom delta.
    private static let pinchZoomScale: Float = 0.3
}
#endif
