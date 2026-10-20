import Maquette
@testable import MaquetteNext
import SwiftUI
import Testing

@Suite("Next camera command contract")
@MainActor
struct CameraContractTests {
    @Test func initialValuesAndControlledBindingsRetainDifferentOwnership() {
        let region = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 6000)
        var ground = DioramaGroundPosition(region: region)
        var camera = MaquetteNext.DioramaCameraPosition.automatic
        let initial = MaquetteNext.DioramaView(initialRegion: region, initialCamera: .camera(.init(distance: 2)))
        let controlled = MaquetteNext.DioramaView(
            groundPosition: Binding(get: { ground }, set: { ground = $0 }),
            cameraPosition: Binding(get: { camera }, set: { camera = $0 })
        )
        camera = .camera(.init(distance: 3))
        ground = .init(region: .init(center: region.center, radius: 3000))
        if case .initial(let value) = initial.camera { #expect(value.camera?.distance == 2) }
        else { Issue.record("Initial camera became controlled") }
        if case .controlled(let binding) = controlled.camera { #expect(binding.wrappedValue.camera?.distance == 3) }
        else { Issue.record("Controlled camera lost its binding") }
        if case .controlled(let binding) = controlled.ground { #expect(binding.wrappedValue.region.radius == 3000) }
        else { Issue.record("Controlled ground lost its binding") }
    }

    @Test func legacyAnglesPreserveViewingDirection() {
        for azimuth in [0.0, 90, 180, 270] {
            let legacy = Maquette.DioramaCamera(azimuth: .degrees(azimuth), elevation: .degrees(26), distance: 2)
            let camera = MaquetteNext.DioramaCamera(legacy: legacy)
            #expect(abs(camera.pitch.degrees - 64) < 0.0001)
            // Existing forward is (-sin(azimuth), -cos(azimuth)) in east/south axes.
            #expect(abs(sin(camera.heading.radians) + sin(legacy.azimuth.radians)) < 0.0001)
            #expect(abs(-cos(camera.heading.radians) + cos(legacy.azimuth.radians)) < 0.0001)
            #expect(camera.distance == 2)
        }
    }

    @Test func limitsRejectInvalidInputsAndPermitOverhead() {
        #expect(DioramaCameraLimits(distance: 0.3...3, pitchDegrees: 0...80) != nil)
        #expect(DioramaCameraLimits(distance: 0...3) == nil)
        #expect(DioramaCameraLimits(distance: 1...Float.infinity) == nil)
        #expect(DioramaCameraLimits(distance: 1...3, pitchDegrees: -1...80) == nil)
        #expect(DioramaCameraLimits(distance: 1...3, pitchDegrees: 0...91) == nil)
    }

    @Test func disconnectedProxyDoesNotPretendRenderingSucceeded() {
        let proxy = DioramaCameraProxy(host: CameraActionHost())
        #expect(proxy.fit(.chunk) == .unavailable)
        #expect(proxy.setCamera(.init()) == .unavailable)
        #expect(proxy.reset() == .unavailable)
    }

    @Test func repeatedEqualActionsExecuteAndSupersededCompletionCannotFinishNewRequest() throws {
        let host = CameraActionHost()
        host.capabilities = .orbit
        var commands: [DioramaCameraRequestID] = []
        var cancelled: [DioramaCameraRequestID] = []
        host.receive = { id, _ in commands.append(id) }
        host.cancel = { cancelled.append($0) }
        let proxy = DioramaCameraProxy(host: host)
        guard case .accepted(let first) = proxy.fit(.chunk),
              case .accepted(let second) = proxy.fit(.chunk) else { Issue.record("Host refused fit"); return }
        #expect(first != second)
        #expect(commands == [first, second])
        #expect(cancelled == [first])
        host.complete(first)
        #expect(host.activeRequest == second)
        proxy.cancel()
        #expect(cancelled == [first, second])
        #expect(host.activeRequest == nil)
        proxy.cancel()
        #expect(cancelled.count == 2)
    }

    @Test func actionHostsDoNotShareCancellationOrCapabilities() {
        let a = CameraActionHost(), b = CameraActionHost()
        a.capabilities = .orbit
        a.receive = { _, _ in }
        #expect(DioramaCameraProxy(host: b).fit(.chunk) == .unavailable)
        _ = DioramaCameraProxy(host: a).fit(.chunk)
        DioramaCameraProxy(host: b).cancel()
        #expect(a.activeRequest != nil)
        a.capabilities = .unavailable
        #expect(DioramaCameraProxy(host: a).setCamera(.init()) == .unavailable)
    }

    @Test func invalidActionsDoNotInterruptCurrentAction() {
        let host = CameraActionHost()
        host.capabilities = .orbit; host.receive = { _, _ in }
        let proxy = DioramaCameraProxy(host: host)
        _ = proxy.fit(.chunk)
        let active = host.activeRequest
        #expect(proxy.fit(.chunk, transition: .easeInOut(duration: -.infinity)) == .invalidRequest)
        #expect(proxy.fit(.contentIDs([])) == .invalidRequest)
        #expect(proxy.setCamera(.init(distance: .nan)) == .invalidRequest)
        #expect(host.activeRequest == active)
    }

    @Test func capabilitiesDistinguishPresentationAndActualSurfaceSupport() {
        #expect(DioramaCapabilities(presentation: .orbit, surface: .raster).camera.canOrbit)
        #expect(!DioramaCapabilities(presentation: .augmentedReality, surface: .raster).camera.canFit)
        #expect(!DioramaCapabilities(presentation: .volume, surface: .raster).camera.canOrbit)
        #expect(!DioramaCapabilities(presentation: .orbit, surface: .photorealisticWithoutQueries).canDrapeAreas)
        #expect(DioramaCapabilities(presentation: .orbit, surface: .photorealisticWithPointQueries).canClampToSurface)
        #expect(!DioramaCapabilities(presentation: .orbit, surface: .photorealisticWithPointQueries).canDrapeAreas)
        #expect(DioramaCapabilities(presentation: .orbit, surface: .photorealisticWithDraping).canDrapeAreas)
    }
}
