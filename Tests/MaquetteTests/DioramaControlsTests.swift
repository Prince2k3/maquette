import CoreLocation
import Foundation
import SwiftUI
import Testing
@testable import Maquette

private actor ControlsTilesProvider: Tiles3DProvider {
    nonisolated let attribution = "Controls fixture"
    private var requests: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func fetchTileset() async throws -> Data {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            requests[index] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func fetchTileContent(uri: String) async throws -> Data {
        Issue.record("An empty controls fixture must not fetch tile content")
        return Data()
    }
    func waitForRequests(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
    func succeed(_ index: Int) {
        requests.removeValue(forKey: index)?.resume(returning: Data("""
        {"asset":{"version":"1.0"},"geometricError":0,"root":{
          "boundingVolume":{"sphere":[6378137,0,0,1]},"geometricError":0}}
        """.utf8))
    }
    func requestCount() -> Int { count }
}

@MainActor
private final class ControlsCompletion {
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func finish() { completed = true; waiter?.resume(); waiter = nil }
    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@Suite("Scoped diorama controls")
@MainActor
struct DioramaControlsTests {
    private static let home = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 1_000)
    private func configuration(_ provider: ControlsTilesProvider) -> DioramaConfiguration {
        DioramaConfiguration(center: Self.home.center.clLocationCoordinate, radiusMeters: Self.home.radius,
                             panRange: 1, presentation: .photorealistic(provider: provider))
    }

    @Test("Compass accessibility heading wraps both negative and full-turn headings")
    func headingNormalization() {
        for (input, expected) in [(-90.0, 270), (450, 90), (359.9, 0)] {
            let state = DioramaControlState(canReset: false, heading: .degrees(input),
                                            canFaceNorth: false, reset: {}, faceNorth: {})
            #expect(state.headingDegrees == expected)
        }
    }

    @Test("Read-back and unchanged style input cannot replace the last requested home")
    func navigationHomeTracksApplicationRequests() async {
        let provider = ControlsTilesProvider()
        let store = DioramaStore(configuration: configuration(provider))
        let navigation = DioramaNavigationController()
        navigation.configureHome(Self.home, followsInput: true)
        let requested = DioramaRegion(center: Coordinate(latitude: 40, longitude: 10), radius: 2_000)
        let completion = ControlsCompletion()
        var bound = DioramaGroundPosition(region: Self.home)
        navigation.binding = Binding(get: { bound }, set: { bound = $0 })
        #expect(navigation.applyRequest(DioramaGroundPosition(region: requested), store: store,
            content: { nil }, writesRequest: true, afterLoad: { completion.finish() }))
        #expect(bound.region == requested)
        #expect(!bound.positionedByUser)
        await provider.waitForRequests(1)
        await provider.succeed(0)
        await completion.wait()
        navigation.configureHome(Self.home, followsInput: true)
        navigation.interactionBegan()
        navigation.publish(from: store)
        #expect(!navigation.applyRequest(bound, store: store, content: { nil }, afterLoad: {}))
        #expect(navigation.homeRegion == requested)
        navigation.interactionEnded(store: store)
        let changed = DioramaRegion(center: Self.home.center, radius: 3_000)
        navigation.configureHome(changed, followsInput: true)
        #expect(navigation.homeRegion == changed)
        navigation.configureHome(Self.home, followsInput: false)
        #expect(navigation.homeRegion == changed)
    }

    @Test("Canceling queued pan preserves the scene generation and discards its scheduled flush")
    func cancelQueuedPan() async {
        let store = DioramaStore(configuration: configuration(ControlsTilesProvider()))
        let generation = store.loadGeneration
        let offset = store.panOffset
        store.pan(by: SIMD2(0.1, 0.2))
        #expect(store.hasPendingPan)
        store.cancelPendingPan()
        #expect(!store.hasPendingPan)
        #expect(store.loadGeneration == generation)
        // A main-actor barrier lets the already-enqueued flush attempt run.
        await Task { @MainActor in }.value
        #expect(store.panOffset == offset)
        #expect(!store.hasPendingPan)
    }

    #if os(iOS) || os(macOS)
    private func loadedModel(_ provider: ControlsTilesProvider) async -> OrbitDioramaModel {
        let model = OrbitDioramaModel(configuration: configuration(provider), content: nil)
        let task = Task { await model.initialLoad(effect: .none) }
        await provider.waitForRequests(1)
        await provider.succeed(0)
        await task.value
        return model
    }

    @Test("A scoped compass changes only its host and publishes a programmatic camera")
    func compassTargetsHost() async {
        let provider = ControlsTilesProvider()
        let model = await loadedModel(provider)
        let other = OrbitDioramaModel(configuration: configuration(ControlsTilesProvider()), content: nil)
        let homeCamera = DioramaCamera(azimuth: .degrees(65), elevation: .degrees(35), distance: 1.4)
        model.applyCameraPosition(.camera(homeCamera))
        var bound = DioramaCameraPosition.camera(homeCamera)
        model.positionBinding = Binding(get: { bound }, set: { bound = $0 })
        var updates: [DioramaCameraChangeContext] = []
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .continuous) { updates.append($0) }
        let before = model.resolvedCamera
        let otherBefore = other.resolvedCamera
        let generation = model.store.loadGeneration
        model.controlState.faceNorth()
        #expect(model.resolvedCamera.azimuth == .zero)
        #expect(model.resolvedCamera.elevation == before.elevation)
        #expect(model.resolvedCamera.distance == before.distance)
        #expect(other.resolvedCamera == otherBefore)
        #expect(!bound.positionedByUser)
        #expect(bound.camera == model.resolvedCamera)
        #expect(updates.last?.origin == .programmatic)
        #expect(model.store.loadGeneration == generation)
        #expect(await provider.requestCount() == 1)

        // Gesture read-back must not replace the app's requested home camera.
        model.cameraController.azimuth = 1.8
        model.publishCameraPosition()
        #expect(bound.positionedByUser)
        model.applyCameraPosition(bound)
        let completion = ControlsCompletion()
        model.navigation.action = DioramaNavigationAction(frequency: .continuous) { _ in completion.finish() }
        model.controlState.reset()
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await completion.wait()
        #expect(abs(model.resolvedCamera.azimuth.degrees - 65) < 0.001)
        #expect(model.resolvedCamera.elevation == before.elevation)
        #expect(model.resolvedCamera.distance == before.distance)
        #expect(!bound.positionedByUser)
    }

    @Test("Reset restores the requested ground after pan and cancels an active globe leg")
    func resetGroundAndGlobe() async {
        let provider = ControlsTilesProvider()
        let model = await loadedModel(provider)
        var bound = DioramaGroundPosition(region: Self.home)
        model.syncNavigation(binding: Binding(get: { bound }, set: { bound = $0 }), action: nil)
        let requested = DioramaRegion(center: Coordinate(latitude: 40, longitude: 10), radius: 2_000)
        let requestedCompletion = ControlsCompletion()
        model.navigation.action = DioramaNavigationAction(frequency: .continuous) { _ in requestedCompletion.finish() }
        model.applyGroundPosition(DioramaGroundPosition(region: requested))
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await requestedCompletion.wait()
        model.navigation.interactionBegan()
        model.store.setPanOffset(SIMD2(0.1, 0))
        model.navigation.publish(from: model.store)
        model.endInteraction()
        #expect(bound.positionedByUser)
        #expect(bound.region != requested)
        #expect(model.navigation.homeRegion == requested)
        model.transition.style = GlobeTransitionStyle()
        _ = model.transition.absorb(zoomDelta: -1, cameraDistance: model.cameraController.distance,
                                   cameraElevation: model.cameraController.elevation, chunkHasRoom: false)
        model.advanceTransition(at: Date())
        #expect(model.transition.isBusy)
        #expect(model.controlState.heading == nil)
        #expect(model.controlState.canReset)
        let resetCompletion = ControlsCompletion()
        model.navigation.action = DioramaNavigationAction(frequency: .continuous) { _ in resetCompletion.finish() }
        model.controlState.reset()
        #expect(!model.transition.isBusy)
        #expect(!model.transition.isShowingGlobe)
        #expect(model.lastTransitionDate == nil)
        #expect(bound.region == requested)
        #expect(!bound.positionedByUser)
        await provider.waitForRequests(3)
        await provider.succeed(2)
        await resetCompletion.wait()
        #expect(model.store.visibleGroundRegion == requested)
        #expect(model.store.panOffset == .zero)
    }

    @Test("Loading and pending requests disable controls; route following hides compass")
    func capabilitiesAndResetRetention() async {
        let provider = ControlsTilesProvider()
        let model = OrbitDioramaModel(configuration: configuration(provider), content: nil)
        #expect(!model.controlState.canReset)
        #expect(!model.controlState.canFaceNorth)
        let task = Task { await model.initialLoad(effect: .none) }
        await provider.waitForRequests(1)
        #expect(!model.controlState.canReset)
        #expect(!model.controlState.canFaceNorth)
        await provider.succeed(0)
        await task.value
        #expect(model.controlState.canReset)
        #expect(model.controlState.canFaceNorth)
        let playback = RoutePreviewController()
        playback.progress = 0.4
        playback.play()
        model.routePreviewController = playback
        model.cameraController.followMode = .following
        #expect(model.controlState.heading == nil)
        #expect(!model.controlState.canFaceNorth)
        #if os(iOS)
        model.arPlacementActive = true
        #expect(model.controlState.heading == nil)
        model.arPlacementActive = false
        #endif
        let selected = UUID()
        var selection: UUID? = selected
        model.selectionBinding = DioramaSelection(Binding(get: { selection }, set: { selection = $0 }))
        model.store.setEffect(.ink)
        let content = DioramaContentGroup {
            DioramaMarker("Retained", coordinate: Self.home.center)
        }
        model.setContent(content)
        let completion = ControlsCompletion()
        model.navigation.action = DioramaNavigationAction(frequency: .continuous) { _ in completion.finish() }
        model.store.pan(by: SIMD2(0.1, 0))
        model.controlState.reset()
        #expect(!model.store.hasPendingPan)
        #expect(model.cameraController.followMode == .orbit)
        #expect(playback.playbackState == .playing)
        #expect(playback.progress == 0.4)
        #expect(!model.controlState.canReset)
        #expect(!model.controlState.canFaceNorth)
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await completion.wait()
        #expect(model.store.effect == .ink)
        #expect(model.content == content)
        #expect(selection == selected)
        #expect(model.store.configuration.panRange == 1)
        #expect(model.controlState.canReset)
        #expect(model.controlState.canFaceNorth)
    }
    #endif
}
