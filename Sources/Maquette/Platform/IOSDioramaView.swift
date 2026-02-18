#if os(iOS)
import SwiftUI
import RealityKit

/// iOS presentation of the diorama with embedded RealityView and touch gestures.
///
/// Uses a `CameraController` for orbit camera and touch gesture handling:
/// - Single finger drag → rotate orbit camera
/// - Pinch → zoom
/// - Two-finger pan → translate
struct IOSDioramaView<Annotations: View>: View {
    let configuration: DioramaConfiguration
    let annotations: ((DioramaProxy) -> Annotations)?

    @State private var viewModel: DioramaViewModel
    @State private var cameraController = CameraController()
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0
    @State private var viewSize: CGSize = CGSize(width: 400, height: 400)

    init(configuration: DioramaConfiguration, annotations: ((DioramaProxy) -> Annotations)?) {
        self.configuration = configuration
        self.annotations = annotations
        self._viewModel = State(initialValue: DioramaViewModel(configuration: configuration))
    }

    var body: some View {
        ZStack {
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

            if case .loading = viewModel.loadingState {
                ProgressView("Loading terrain...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if case .failed(let error) = viewModel.loadingState {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Failed to load diorama")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            if let elevation = configuration.cameraElevation {
                cameraController.elevation = elevation
            }
            if let distance = configuration.cameraDistance {
                cameraController.distance = distance
            }
            await viewModel.load()
        }
    }

    private func updateEntityScale() {
        guard let entity = viewModel.dioramaEntity else { return }
        // Scale entity so the diorama fills roughly 70% of the smaller view dimension
        let referenceSize: CGFloat = 400.0 // Baseline view size the default physicalDiameter is designed for
        let scaleFactor = Float(min(viewSize.width, viewSize.height) / referenceSize)
        entity.scale = SIMD3<Float>(repeating: scaleFactor)
    }

    @ViewBuilder
    private var realityContent: some View {
        RealityView { content in
            let camera = PerspectiveCamera()
            camera.name = "OrbitCamera"
            camera.camera.fieldOfViewInDegrees = 60
            content.add(camera)

            // Key light — directional from above-left to cast shadows across terrain
            let sunLight = DirectionalLight()
            sunLight.name = "SunLight"
            sunLight.light.intensity = 1200
            sunLight.light.color = .white
            sunLight.shadow = .init()
            sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
            content.add(sunLight)

            // Fill light — softer from the opposite side to prevent pure-black shadows
            let fillLight = PointLight()
            fillLight.name = "FillLight"
            fillLight.light.intensity = 300
            fillLight.light.color = .white
            fillLight.light.attenuationRadius = 5.0
            fillLight.position = SIMD3<Float>(0.5, 0.8, 0.5)
            content.add(fillLight)

            if let entity = viewModel.dioramaEntity {
                content.add(entity)
            }
        } update: { content in
            if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                camera.transform = cameraController.cameraTransform
            }

            if let entity = viewModel.dioramaEntity,
               !content.entities.contains(where: { $0.name == "Maquette" }) {
                content.add(entity)
                updateEntityScale()
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
