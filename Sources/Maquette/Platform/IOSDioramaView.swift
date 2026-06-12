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
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0
    @State private var viewSize: CGSize = CGSize(width: 400, height: 400)
    @State private var lastAnimationDate: Date?

    @Environment(\.routePreviewController) private var routePreviewController

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
        .dioramaLoadingOverlay(state: store.loadingState)
        .task {
            if let elevation = configuration.cameraElevation {
                cameraController.elevation = elevation
            }
            if let distance = configuration.cameraDistance {
                cameraController.distance = distance
            }
            await store.load()
            store.applyContent(content)
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

    private func updateEntityScale() {
        guard let entity = store.dioramaEntity else { return }
        let referenceSize: CGFloat = 400.0
        let scaleFactor = Float(min(viewSize.width, viewSize.height) / referenceSize)
        entity.scale = SIMD3<Float>(repeating: scaleFactor)
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

            // Drive 3D Tiles LOD updates from camera position changes
            if let tiles3D = (store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: cameraController.cameraPosition,
                    screenHeight: Float(viewSize.height),
                    fov: 60 * .pi / 180
                )
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let dx = Float(value.translation.width - lastDragTranslation.width)
                    let dy = Float(value.translation.height - lastDragTranslation.height)
                    lastDragTranslation = value.translation
                    cameraController.rotate(deltaX: dx, deltaY: dy)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let delta = Float(value.magnification - lastMagnification) * 5.0
                    lastMagnification = value.magnification
                    cameraController.zoom(delta: delta)
                }
                .onEnded { _ in
                    lastMagnification = 1.0
                }
        )
    }
}
#endif
