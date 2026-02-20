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

    @State private var viewModel: DioramaViewModel

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.configuration = configuration
        self.content = content
        self._viewModel = State(initialValue: DioramaViewModel(configuration: configuration))
    }

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content, attachments in
                // Key light
                let sunLight = DirectionalLight()
                sunLight.name = "SunLight"
                sunLight.light.intensity = 1200
                sunLight.light.color = .white
                sunLight.shadow = .init()
                sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
                content.add(sunLight)
            } update: { realityViewContent, attachments in
                if let entity = viewModel.dioramaEntity,
                   !realityViewContent.entities.contains(where: { $0.name == "Maquette" }) {
                    // Get volume bounds in scene coordinates
                    let volumeBounds = realityViewContent.convert(
                        geometry.frame(in: .local), from: .local, to: .scene
                    )
                    let volumeWidth = volumeBounds.max.x - volumeBounds.min.x
                    let volumeDepth = volumeBounds.max.z - volumeBounds.min.z

                    // Scale entity to fill the volume snugly
                    let dioramaDiameter = configuration.physicalDiameter
                    let fitScale = min(volumeWidth, volumeDepth) / dioramaDiameter
                    entity.scale = SIMD3<Float>(repeating: fitScale)

                    // Position at the bottom of the volume with padding
                    // 40pt ≈ 0.014m in scene coordinates (1pt ≈ 0.000352m at standard density)
                    let bottomPadding: Float = 0.014
                    entity.position.y = volumeBounds.min.y + bottomPadding

                    realityViewContent.add(entity)
                }
            } attachments: {
            }
            .task {
                await viewModel.load()
                viewModel.applyContent(content)
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
                            let newScale = Float(value.magnification)
                            entity.scale = SIMD3<Float>(repeating: max(0.3, min(newScale, 3.0)))
                        }
                    }
            )
        }
    }
}
#endif
