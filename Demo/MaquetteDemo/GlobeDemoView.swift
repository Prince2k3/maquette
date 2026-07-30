import Maquette
import RealityKit
import SwiftUI

/// The globe on its own, so it can be looked at before anything is built on top of it.
///
/// Deliberately a separate screen rather than a mode inside `DioramaView`: how the globe and the
/// chunk hand off to each other is an open design question, and putting the globe inside the view
/// that renders the chunk would answer it by accident.
///
/// One finger orbits, pinch zooms — the same `CameraController` the diorama views use, which is the
/// point. Its azimuth is a longitude and its elevation a latitude on this sphere, because
/// `GlobeGeometry` shares its spherical convention.
struct GlobeDemoView: View {
    @State private var globe: GlobeEntity?
    @State private var failure: String?
    @State private var cameraController = CameraController()

    private static let radius: Float = 0.5

    var body: some View {
        ZStack {
            RealityView { content in
                let camera = PerspectiveCamera()
                camera.name = "OrbitCamera"
                camera.camera.fieldOfViewInDegrees = 60
                content.add(camera)

                if let globe { content.add(globe) }
            } update: { content in
                if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                    camera.transform = cameraController.cameraTransform
                }
                if let globe, !content.entities.contains(where: { $0.name == "Globe" }) {
                    content.add(globe)
                }
            }
            .gesture(orbit)
            .simultaneousGesture(pinch)

            if globe == nil {
                overlay
            }
        }
        .task {
            cameraController.distance = 1.6
            cameraController.elevation = 0.4
            do {
                globe = try await GlobeEntity.make(radius: Self.radius, zoom: 3)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let failure {
            VStack(spacing: 6) {
                Text("Could not load the world")
                    .font(.subheadline.weight(.medium))
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        } else {
            ProgressView()
        }
    }

    private var orbit: some Gesture {
        DragGesture()
            .onChanged { value in
                // Deltas rather than the running translation, so the sphere tracks the finger instead
                // of accelerating away from it.
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                cameraController.rotate(deltaX: Float(delta.width), deltaY: Float(delta.height))
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = Float(value.magnification - lastMagnification)
                lastMagnification = value.magnification
                cameraController.zoom(delta: delta * 200)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
}
