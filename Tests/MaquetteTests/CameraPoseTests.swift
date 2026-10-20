#if os(iOS) || os(macOS)
import RealityKit
import simd
import Testing
@testable import Maquette

@Suite("Camera pose and fitting")
@MainActor
struct CameraPoseTests {
    @Test func overheadRetainsHeadingWithoutSingularUpVector() {
        let controller = CameraController()
        controller.elevation = .pi / 2
        controller.azimuth = .pi / 2
        let right = controller.cameraTransform.matrix.columns.0
        #expect(abs(right.x) < 0.0001)
        #expect(abs(right.z + 1) < 0.0001)
        #expect(controller.cameraTransform.rotation.vector.allFinite)
    }
    @Test func overheadReadbackRemainsValidForSubsequentActions() {
        let model = OrbitDioramaModel(configuration: .init(center: .init(latitude: 36, longitude: -112), radiusMeters: 1000), content: nil)
        model.applyCameraPosition(.camera(.init(pitch: .zero)))
        #expect(model.resolvedCamera.isValid)
        #expect(model.resolvedCamera.pitch == .zero)
        var east = model.resolvedCamera
        east.heading = .degrees(90)
        model.applyCameraPosition(.camera(east))
        #expect(abs(model.resolvedCamera.heading.degrees - 90) < 0.001)
    }

}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
#endif
