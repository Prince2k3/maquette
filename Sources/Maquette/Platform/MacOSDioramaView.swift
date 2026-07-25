#if os(macOS)
import SwiftUI
import RealityKit
@preconcurrency import _RealityKit_SwiftUI

/// macOS presentation of the diorama with embedded RealityView and trackpad/mouse controls.
///
/// Uses the same `CameraController` as iOS with different input mappings:
/// - Click + drag → rotate orbit camera
/// - Scroll wheel / trackpad scroll → zoom
/// - Right-click drag → pan
struct MacOSDioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    @State private var store: DioramaStore
    @State private var cameraController = CameraController()
    @State private var lastDragTranslation: CGSize = .zero
    @State private var viewSize: CGSize = CGSize(width: 400, height: 400)
    @State private var lastAnimationDate: Date?

    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.enabledDioramaGestures) private var enabledGestures

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
        .dioramaLoadingOverlay(state: store.loadingState) {
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

            // Drive 3D Tiles LOD updates from camera position changes
            if let tiles3D = (store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: cameraController.cameraPosition,
                    screenHeight: Float(viewSize.height),
                    fov: 60 * .pi / 180
                )
            }
        }
        .gestureIf(enabledGestures.contains(.rotate),
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
        // Terrain panning takes the drag only when orbiting has been turned off, so the two
        // never contend for the same gesture.
        .gestureIf(enabledGestures.contains(.pan) && !enabledGestures.contains(.rotate),
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let dx = Float(value.translation.width - lastDragTranslation.width)
                    let dy = Float(value.translation.height - lastDragTranslation.height)
                    lastDragTranslation = value.translation
                    store.pan(by: cameraController.terrainPanDelta(
                        dragDeltaX: dx,
                        dragDeltaY: dy,
                        viewHeight: Float(viewSize.height),
                        entityScale: entityScale
                    ))
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            guard enabledGestures.contains(.zoom) else { return }
            cameraController.zoom(delta: Float(newValue) * 0.1)
        }
    }
}
#endif
