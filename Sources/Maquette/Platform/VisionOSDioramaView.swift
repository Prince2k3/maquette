#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS presentation of the diorama using volumetric RealityView.
///
/// No virtual camera is needed — the user physically moves around the diorama.
/// Gestures: pinch-drag to rotate, pinch-spread to zoom.
struct VisionOSDioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    @State private var store: DioramaStore

    @Environment(\.routePreviewController) private var routePreviewController

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.configuration = configuration
        self.content = content
        self._store = State(initialValue: DioramaStore(configuration: configuration))
    }

    var body: some View {
        GeometryReader3D { geometry in
            realityContent(geometry: geometry)
                .dioramaLoadingOverlay(state: store.loadingState)
                .task {
                    await store.load()
                    store.applyContent(content)
                }
                .gesture(
                    DragGesture()
                        .targetedToAnyEntity()
                        .onChanged { value in
                            if let entity = store.dioramaEntity {
                                let delta = Float(value.translation.width) * 0.01
                                let rotation = simd_quatf(angle: delta, axis: SIMD3<Float>(0, 1, 0))
                                entity.orientation = rotation * entity.orientation
                            }
                        }
                )
                .gesture(
                    MagnifyGesture()
                        .targetedToAnyEntity()
                        .onChanged { value in
                            if let entity = store.dioramaEntity {
                                let newScale = Float(value.magnification)
                                entity.scale = SIMD3<Float>(repeating: max(0.3, min(newScale, 3.0)))
                            }
                        }
                )
        }
    }

    @ViewBuilder
    private func realityContent(geometry: GeometryProxy3D) -> some View {
        let isPlaying = routePreviewController?.playbackState == .playing
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            realityView(geometry: geometry)
                .onChange(of: timeline.date) { _, newDate in
                    advanceAnimation(at: newDate)
                }
        }
    }

    private func advanceAnimation(at date: Date) {
        guard let controller = routePreviewController else { return }
        controller.update(at: date)
        if let routeEntity = store.routePreviewEntity {
            routeEntity.updateProgress(controller.progress)
        }
    }

    private func realityView(geometry: GeometryProxy3D) -> some View {
        RealityView { content, attachments in
            let sunLight = DirectionalLight()
            sunLight.name = "SunLight"
            sunLight.light.intensity = 1200
            sunLight.light.color = .white
            sunLight.shadow = .init()
            sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
            content.add(sunLight)
        } update: { realityViewContent, attachments in
            if let entity = store.dioramaEntity,
               !realityViewContent.entities.contains(where: { $0.name == "Maquette" }) {
                let volumeBounds = realityViewContent.convert(
                    geometry.frame(in: .local), from: .local, to: .scene
                )
                let volumeWidth = volumeBounds.max.x - volumeBounds.min.x
                let volumeDepth = volumeBounds.max.z - volumeBounds.min.z

                let dioramaDiameter = configuration.physicalDiameter
                let fitScale = min(volumeWidth, volumeDepth) / dioramaDiameter
                entity.scale = SIMD3<Float>(repeating: fitScale)

                let bottomPadding: Float = 0.014
                entity.position.y = volumeBounds.min.y + bottomPadding

                realityViewContent.add(entity)
            }

            // Drive 3D Tiles LOD updates — use a default overhead viewing position
            if let tiles3D = (store.dioramaEntity as? DioramaEntity)?.tiles3D {
                let defaultCamera = SIMD3<Float>(0, 0.5, 0.5)
                tiles3D.requestLODUpdate(
                    cameraPosition: defaultCamera,
                    screenHeight: 1080,
                    fov: 60 * .pi / 180
                )
            }
        } attachments: {
        }
    }
}
#endif
