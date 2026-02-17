#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS presentation of the diorama using volumetric RealityView.
///
/// No virtual camera is needed — the user physically moves around the diorama.
/// Gestures: pinch-drag to rotate, pinch-spread to zoom.
struct VisionOSDioramaView<Annotations: View>: View {
    let configuration: DioramaConfiguration
    let annotations: ((DioramaProxy) -> Annotations)?

    @State private var viewModel: DioramaViewModel
    @State private var baseScale: Float = 1.0

    init(configuration: DioramaConfiguration, annotations: ((DioramaProxy) -> Annotations)?) {
        self.configuration = configuration
        self.annotations = annotations
        self._viewModel = State(initialValue: DioramaViewModel(configuration: configuration))
    }

    var body: some View {
        RealityView { content, attachments in
            // Key light — directional from above-left for terrain shadow contrast
            let sunLight = DirectionalLight()
            sunLight.name = "SunLight"
            sunLight.light.intensity = 1200
            sunLight.light.color = .white
            sunLight.shadow = .init()
            sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
            content.add(sunLight)
        } update: { content, attachments in
            // Add the diorama entity once it's loaded
            if let entity = viewModel.dioramaEntity,
               !content.entities.contains(where: { $0.name == "Maquette" }) {
                content.add(entity)
            }
        } attachments: {
            // visionOS attachments for annotation labels
        }
        .task {
            await viewModel.load()
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    if let entity = viewModel.dioramaEntity {
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
                    if let entity = viewModel.dioramaEntity {
                        let newScale = baseScale * Float(value.magnification)
                        entity.scale = SIMD3<Float>(repeating: max(0.1, min(newScale, 5.0)))
                    }
                }
                .onEnded { _ in
                    if let entity = viewModel.dioramaEntity {
                        baseScale = entity.scale.x
                    }
                }
        )
    }
}
#endif
