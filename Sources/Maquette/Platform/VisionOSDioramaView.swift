#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS presentation of the diorama using volumetric RealityView.
///
/// Adapts to volume size changes (user resize, Window Zoom accessibility setting) using
/// the `GeometryReader3D` + `content.convert` pattern documented by Apple engineering.
/// A dedicated scaling entity wraps the diorama so that `content.convert` can compute
/// the correct points-to-meters ratio on every layout pass.
///
/// No virtual camera is needed — the user physically moves around the diorama.
/// Gestures: pinch-drag to rotate, pinch-spread to zoom.
struct VisionOSDioramaView<Annotations: View>: View {
    let configuration: DioramaConfiguration
    let annotations: ((DioramaProxy) -> Annotations)?

    @State private var viewModel: DioramaViewModel

    /// Persistent scaling wrapper entity — lives across make/update cycles.
    /// The diorama entity is added as a child of this; scaling is applied here
    /// so the diorama's own transform stays clean for rotation/interaction.
    @State private var scalingEntity = Entity()

    init(configuration: DioramaConfiguration, annotations: ((DioramaProxy) -> Annotations)?) {
        self.configuration = configuration
        self.annotations = annotations
        self._viewModel = State(initialValue: DioramaViewModel(configuration: configuration))
    }

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                // Add the scaling wrapper to the scene once
                content.add(scalingEntity)

                // Key light
                let sunLight = DirectionalLight()
                sunLight.name = "SunLight"
                sunLight.light.intensity = 1200
                sunLight.light.color = .white
                sunLight.shadow = .init()
                sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
                content.add(sunLight)

                // Apply initial scale
                applyVolumeScale(content: content, proxy: proxy)
            } update: { content in
                // Add the diorama as a child of the scaling entity once loaded
                if let entity = viewModel.dioramaEntity,
                   !scalingEntity.children.contains(where: { $0.name == "Maquette" }) {
                    scalingEntity.addChild(entity)
                }

                // Re-apply scale — this runs on every layout change because
                // GeometryReader3D re-evaluates its body (and thus recreates or
                // updates the RealityView) when the volume size changes.
                applyVolumeScale(content: content, proxy: proxy)
            }
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
                        let newScale = Float(value.magnification)
                        entity.scale = SIMD3<Float>(repeating: max(0.3, min(newScale, 3.0)))
                    }
                }
        )
    }

    /// Computes the volume's physical size in meters via `content.convert` and
    /// applies a uniform scale to `scalingEntity` so the diorama fits inside.
    private func applyVolumeScale(content: RealityViewContent, proxy: GeometryProxy3D) {
        let sceneBounds = content.convert(
            proxy.frame(in: .local),
            from: .local,
            to: .scene
        )
        let extents = sceneBounds.extents

        guard extents.x > 0, extents.y > 0, extents.z > 0 else { return }

        // The diorama's unscaled physical extent
        let rimThickness: Float = 0.015
        let dioramaWidth = configuration.physicalDiameter + rimThickness * 2
        let dioramaHeight = configuration.physicalDiameter * 0.5
        let dioramaDepth = dioramaWidth

        // Uniform scale to fit within the volume with padding
        let padding: Float = 0.9
        let scaleX = extents.x / dioramaWidth
        let scaleY = extents.y / dioramaHeight
        let scaleZ = extents.z / dioramaDepth
        let fitScale = min(scaleX, min(scaleY, scaleZ)) * padding

        scalingEntity.scale = SIMD3<Float>(repeating: fitScale)
    }
}
#endif
