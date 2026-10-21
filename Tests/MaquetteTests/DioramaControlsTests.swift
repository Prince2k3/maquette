import CoreLocation
import Foundation
import simd
import RealityKit
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

    @Test("Camera actions advance by elapsed time and finish exactly once")
    func timedCameraActions() async throws {
        let model = await loadedModel(ControlsTilesProvider())
        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.cameraClock = { start }
        model.applyCameraPosition(.camera(DioramaCamera(heading: .degrees(359), pitch: .degrees(30), distance: 1)))
        var events: [DioramaCameraChangeContext] = []
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .continuous) { events.append($0) }
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        guard case .accepted(let id) = proxy.setCamera(DioramaCamera(heading: .degrees(1), pitch: .zero, distance: 2),
            transition: .easeInOut(duration: 2)) else { Issue.record("Expected camera action"); return }
        #expect(model.cameraMotion != nil)
        model.advanceAnimation(at: start.addingTimeInterval(0.5))
        #expect(abs(model.resolvedCamera.heading.degrees - 359.3125) < 0.001)
        #expect(events.allSatisfy { $0.phase == .changing })
        model.advanceAnimation(at: start.addingTimeInterval(2))
        #expect(model.cameraMotion == nil)
        #expect(abs(model.resolvedCamera.pitch.degrees) < 0.001)
        #expect(model.resolvedCamera.distance == 2)
        #expect(events.filter { $0.phase == .ended }.count == 1)
        #expect(proxy.result(for: id) == .completed(id, model.resolvedCamera))
        model.advanceAnimation(at: start.addingTimeInterval(5))
        #expect(events.filter { $0.phase == .ended }.count == 1)
    }

    @Test("Gesture cancellation and newer commands retain the actual current camera")
    func cameraCancellationAndLatestRequest() async throws {
        let model = await loadedModel(ControlsTilesProvider())
        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.cameraClock = { start }
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        guard case .accepted(let first) = proxy.setCamera(.init(heading: .degrees(100), pitch: .degrees(20), distance: 2), transition: .easeInOut(duration: 4)) else { Issue.record("Expected action"); return }
        model.advanceAnimation(at: start.addingTimeInterval(1))
        let partial = model.resolvedCamera
        model.interruptCameraForGesture()
        #expect(proxy.result(for: first) == .cancelled(first))
        #expect(model.resolvedCamera.heading == partial.heading)
        #expect(model.resolvedCamera.distance == partial.distance)
        model.endInteraction()
        guard case .accepted(let second) = proxy.setCamera(.init(heading: .degrees(50), distance: 2), transition: .easeInOut(duration: 4)) else { Issue.record("Expected action"); return }
        guard case .accepted(let third) = proxy.setCamera(.init(heading: .degrees(90), distance: 1)) else { Issue.record("Expected action"); return }
        model.advanceAnimation(at: start.addingTimeInterval(10))
        #expect(proxy.result(for: second) == .cancelled(second))
        #expect(proxy.result(for: third) == .completed(third, model.resolvedCamera))
        #expect(abs(model.resolvedCamera.heading.degrees - 90) < 0.001)
    }

    @Test("Camera limits, Reduce Motion, and tracking capabilities share one path")
    func cameraConstraintsAndCapabilities() async throws {
        let model = await loadedModel(ControlsTilesProvider())
        model.configureCamera(limits: DioramaCameraLimits(distance: 0.7...1, pitchDegrees: 0...30)!, transition: .immediate, reduceMotion: true)
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        guard case .accepted(let id) = proxy.setCamera(.init(pitch: .degrees(80), distance: 10), transition: .easeInOut(duration: 20)) else { Issue.record("Expected action"); return }
        #expect(model.cameraMotion == nil)
        #expect(abs(model.resolvedCamera.pitch.degrees - 30) < 0.001)
        #expect(model.resolvedCamera.distance == 1)
        #expect(proxy.result(for: id) == .completed(id, model.resolvedCamera))
        model.arPlacementActive = true
        #expect(!proxy.capabilities.canOrbit)
        #expect(proxy.setCamera(.init()) == .unavailable)
        let before = model.resolvedCamera
        model.applyCameraPosition(.camera(.init(heading: .degrees(90))))
        #expect(model.resolvedCamera == before)
    }

    @Test("Fits report outside ground and missing IDs without reloading terrain")
    func cameraFitResultsAndContentIDs() async throws {
        let provider = ControlsTilesProvider()
        let model = await loadedModel(provider)
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        let generation = model.store.loadGeneration
        guard case .accepted(let outside) = proxy.fit(.bounds(.init(west: -113, south: 37, east: -112.9, north: 37.1))) else { Issue.record("Expected fit"); return }
        await model.cameraFitTask?.value
        #expect(proxy.result(for: outside) == .requiresGroundNavigation(outside))
        guard case .accepted(let missing) = proxy.fit(.contentIDs(["missing"])) else { Issue.record("Expected fit"); return }
        await model.cameraFitTask?.value
        #expect(proxy.result(for: missing) == .invalidTarget(missing))
        model.setContent(DioramaContentGroup { DioramaMarker("Fit", coordinate: Self.home.center, id: "fit") })
        guard case .accepted(let fit) = proxy.fit(.contentIDs(["fit"])) else { Issue.record("Expected fit"); return }
        await model.cameraFitTask?.value
        #expect(proxy.result(for: fit) == .completed(fit, model.resolvedCamera))
        #expect(model.store.loadGeneration == generation)
        #expect(await provider.requestCount() == 1)
    }

    @Test("A programmatic camera settles a locked globe and releases route ownership")
    func cameraOwnershipArbitration() async {
        let model = await loadedModel(ControlsTilesProvider())
        model.cameraController.enterRouteFollowMode(routePoints: [.zero, .init(0.1, 0.1, 0.1)], initialDirection: .init(1, 0))
        model.transition.style = GlobeTransitionStyle()
        _ = model.transition.absorb(zoomDelta: -1, cameraDistance: 1, cameraElevation: 0.5, chunkHasRoom: false)
        #expect(model.isInteractionLocked)
        model.updateCameraCapabilities()
        _ = DioramaCameraProxy(host: model.cameraHost).setCamera(.init(heading: .degrees(45), distance: 1))
        #expect(!model.isInteractionLocked)
        #expect(!model.transition.isShowingGlobe)
        #expect(model.cameraController.followMode == .orbit)
        #expect(abs(model.resolvedCamera.heading.degrees - 45) < 0.001)
    }

    @Test("Observer reentrancy cannot finish a newer timed camera action")
    func cameraObserverLatestRequestWins() async {
        let model = await loadedModel(ControlsTilesProvider())
        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.cameraClock = { start }
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        var newer: DioramaCameraRequestID?
        var submitted = false
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .continuous) { context in
            if !submitted, context.phase == .changing, abs(context.camera.heading.degrees - 90) < 0.001 {
                submitted = true
                if case .accepted(let id) = proxy.setCamera(.init(heading: .degrees(180), distance: 2), transition: .easeInOut(duration: 2)) { newer = id }
            }
        }
        defer { model.cameraObservation.action = nil }
        guard case .accepted(let old) = proxy.setCamera(.init(heading: .degrees(90), distance: 1), transition: .easeInOut(duration: 1)) else { Issue.record("Expected action"); return }
        model.advanceAnimation(at: start.addingTimeInterval(1))
        #expect(proxy.result(for: old) == .cancelled(old))
        #expect(model.cameraMotion?.request == newer)
        model.advanceAnimation(at: start.addingTimeInterval(2))
        if let newer { #expect(proxy.result(for: newer) == .completed(newer, model.resolvedCamera)) }
        else { Issue.record("Observer did not submit its action") }
    }

    @Test("Timed startup focus resolves after loading and stays geographic on pan and reload")
    func cameraFocusTracksLiveProjection() async throws {
        let provider = ControlsTilesProvider()
        let model = OrbitDioramaModel(configuration: configuration(provider), content: nil)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.cameraClock = { start }
        model.syncNavigation(binding: nil, action: nil)
        model.configureCamera(limits: .default, transition: .easeInOut(duration: 10), reduceMotion: false)
        let coordinate = Coordinate(latitude: 36.001, longitude: -112, altitude: 100)
        model.initialCamera = .camera(.init(distance: 1, focus: .coordinate(coordinate, altitude: .absolute)))
        let load = Task { await model.initialLoad(effect: .none) }
        await provider.waitForRequests(1)
        await provider.succeed(0)
        await load.value
        let expected = try #require(model.store.projection?.position(for: coordinate, altitude: .absolute))
        #expect(model.cameraMotion?.to.target == expected)
        model.advanceAnimation(at: start.addingTimeInterval(10))
        #expect(simd_distance(model.cameraController.target, expected) < 0.00001)
        model.store.setPanOffset(.init(0.05, 0))
        let panned = try #require(model.store.projection?.position(for: coordinate, altitude: .absolute))
        #expect(simd_distance(model.cameraController.target, panned) < 0.00001)
        var changed = model.store.configuration
        changed.radiusMeters = 500
        let reload = Task { await model.store.reload(configuration: changed) }
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await reload.value
        let reloaded = try #require(model.store.projection?.position(for: coordinate, altitude: .absolute))
        #expect(simd_distance(model.cameraController.target, reloaded) < 0.00001)
    }

    @Test("Known off-ground markers request navigation instead of becoming missing targets")
    func offGroundMarkerFitRetainsSourceIdentity() async {
        let model = await loadedModel(ControlsTilesProvider())
        model.setContent(DioramaContentGroup { DioramaMarker("Outside", coordinate: Coordinate(latitude: 37, longitude: -112), id: "outside") })
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        guard case .accepted(let id) = proxy.fit(.contentIDs(["outside"])) else { Issue.record("Expected fit"); return }
        await model.cameraFitTask?.value
        #expect(proxy.result(for: id) == .requiresGroundNavigation(id))
    }

    @Test("AR entry rejects camera commands submitted by cancellation observers")
    func arCancellationObserverCannotReclaimCamera() async {
        let model = await loadedModel(ControlsTilesProvider())
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        var attempted: DioramaCameraActionResult?
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .continuous) { context in
            if context.phase == .cancelled {
                attempted = proxy.setCamera(.init(distance: 3), transition: .easeInOut(duration: 2))
            }
        }
        defer { model.cameraObservation.action = nil }
        _ = proxy.setCamera(.init(distance: 2), transition: .easeInOut(duration: 2))
        model.arPlacementActive = true
        #expect(attempted == .unavailable)
        #expect(model.cameraMotion == nil)
    }

    @Test("Chunk fitting includes relief, walls, safe areas, and scoped control insets")
    func cameraFitIncludesEntireSolidAndInsets() async throws {
        let model = await loadedModel(ControlsTilesProvider())
        let root = try #require(model.store.dioramaEntity as? DioramaEntity)
        let (fixture, _) = try OverlayRenderFixture.make()
        root.setTerrain(try #require(fixture.terrain))
        model.viewSize = .init(width: 400, height: 800)
        model.cameraSafeAreaInsets = .init(top: 20, leading: 0, bottom: 30, trailing: 0)
        model.cameraControlInsets = .init(top: 0, leading: 60, bottom: 0, trailing: 0)
        model.cameraFitInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 40)
        model.configureCamera(limits: DioramaCameraLimits(distance: 0.1...20)!, transition: .immediate, reduceMotion: false)
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        guard case .accepted(let id) = proxy.fit(.chunk, padding: .init(top: 10, leading: 10, bottom: 10, trailing: 10)) else { Issue.record("Expected fit"); return }
        await model.cameraFitTask?.value
        #expect(proxy.result(for: id) == .completed(id, model.resolvedCamera))
        for buffer in [root.terrain?.surfaceBuffers, root.terrain?.wallBuffers, root.terrain?.bottomBuffers].compactMap({ $0 }) {
            for p in buffer.positions {
                let screen = try #require(DioramaCameraGeometry.projectedPoint(p, pose: model.cameraPose, viewport: model.viewSize))
                #expect(screen.x >= 70 - 0.05 && screen.x <= 350 + 0.05)
                #expect(screen.y >= 30 - 0.05 && screen.y <= 760 + 0.05)
            }
        }
    }

    @Test("Initial camera ownership is consumed once across view reappearance")
    func initialCameraDoesNotResetOnReappearance() async {
        let provider = ControlsTilesProvider()
        let model = await loadedModel(provider)
        model.applyCameraPosition(.camera(.init(heading: .degrees(110), distance: 2)))
        model.publishCameraPosition()
        let before = model.resolvedCamera
        model.initialCamera = .camera(.init(heading: .degrees(20), distance: 1))
        await model.initialLoad(effect: .none)
        #expect(model.resolvedCamera == before)
        #expect(await provider.requestCount() == 1)
    }

    @Test("Looping playback does not retain camera ownership after a gesture")
    func loopingRouteReleasesCameraObservation() async {
        let model = await loadedModel(ControlsTilesProvider())
        let controller = RoutePreviewController(loops: true)
        model.routePreviewController = controller
        controller.play()
        model.syncNavigation(binding: nil, action: nil)
        model.cameraController.enterRouteFollowMode(routePoints: [.zero, .init(0.1, 0, 0.1)], initialDirection: .init(1, 0))
        var bound = DioramaCameraPosition.automatic
        model.positionBinding = Binding(get: { bound }, set: { bound = $0 })
        model.secondaryDrag(dx: 10, dy: 0)
        model.endInteraction()
        #expect(model.cameraController.followMode == .orbit)
        #expect(model.cameraObservation.isTransitioning?() == false)
        #expect(bound.positionedByUser)
        model.advanceAnimation(at: Date())
        #expect(bound.positionedByUser)
    }

    @Test("A scoped compass changes only its host and publishes a programmatic camera")
    func compassTargetsHost() async {
        let provider = ControlsTilesProvider()
        let model = await loadedModel(provider)
        let other = OrbitDioramaModel(configuration: configuration(ControlsTilesProvider()), content: nil)
        let homeCamera = DioramaCamera(heading: .degrees(-(65)), pitch: .degrees(90 - (35)), distance: 1.4)
        model.applyCameraPosition(.camera(homeCamera))
        var bound = DioramaCameraPosition.camera(homeCamera)
        model.positionBinding = Binding(get: { bound }, set: { bound = $0 })
        var updates: [DioramaCameraChangeContext] = []
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .continuous) { updates.append($0) }
        let before = model.resolvedCamera
        let otherBefore = other.resolvedCamera
        let generation = model.store.loadGeneration
        model.controlState.faceNorth()
        #expect(model.resolvedCamera.heading == .zero)
        #expect(model.resolvedCamera.pitch == before.pitch)
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
        #expect(abs(model.resolvedCamera.heading.degrees - 295) < 0.001)
        #expect(model.resolvedCamera.pitch == before.pitch)
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
    @Test("Explicit unsupported ground input stays inert even under legacy mapping")
    func independentZoomTargets() async {
        let model = await loadedModel(ControlsTilesProvider())
        model.inputConfiguration = .legacyOrbit
        let before = model.resolvedCamera
        #expect(!model.performInput(.zoom(.ground, steps: 1)))
        #expect(model.resolvedCamera == before)
        #expect(!model.controlState.navigation.canGroundZoomIn)
        #expect(model.performInput(.zoom(.camera, steps: 1)))
        #expect(model.resolvedCamera.distance < before.distance)
        model.enabledGestures = [.zoom]
        #expect(!model.performInput(.zoom(.camera, steps: 1)))
    }

    @Test("Heading and pitch permissions are independent and primary drag never falls through")
    func independentAxes() async {
        let model = await loadedModel(ControlsTilesProvider())
        model.enabledGestures = [.heading]
        let first = model.resolvedCamera
        model.orbitInput(headingDegrees: 20, pitchDegrees: 15)
        #expect(abs(model.resolvedCamera.heading.degrees - 20) < 0.001)
        #expect(abs(model.resolvedCamera.pitch.degrees - first.pitch.degrees) < 0.001)
        model.enabledGestures = [.pitch]
        model.orbitInput(headingDegrees: 20, pitchDegrees: 5)
        #expect(abs(model.resolvedCamera.heading.degrees - 20) < 0.001)
        #expect(abs(model.resolvedCamera.pitch.degrees - first.pitch.degrees - 5) < 0.001)
        model.enabledGestures = [.heading, .pitch]
        let beforePan = model.resolvedCamera
        model.primaryDrag(dx: 30, dy: 20)
        #expect(model.resolvedCamera == beforePan)
    }

    @Test("Keyboard focus, custom mappings, and native controls retain their own host")
    func focusedInput() async {
        let first = await loadedModel(ControlsTilesProvider())
        let second = await loadedModel(ControlsTilesProvider())
        let secondCamera = second.resolvedCamera
        first.inputConfiguration.keyboardShortcuts = [.init("x", action: .orbit(heading: 10, pitch: 0))]
        #expect(!first.keyboardInput(key: "x", modifiers: []))
        first.inputFocused = true
        #expect(first.keyboardInput(key: "x", modifiers: []))
        #expect(abs(first.resolvedCamera.heading.degrees - 10) < 0.001)
        #expect(second.resolvedCamera == secondCamera)
        #expect(!first.keyboardInput(key: "x", modifiers: .command))
        let home = first.homeCamera
        first.controlState.navigation.zoom(.camera, 1)
        first.controlState.navigation.setPitch(30)
        #expect(first.homeCamera == home)
        #expect(second.resolvedCamera == secondCamera)
    }

    @Test("Controls apply limits and Reduce Motion without changing reset home")
    func nativeControlLimitsAndMotion() async throws {
        let model = await loadedModel(ControlsTilesProvider())
        let home = model.homeCamera
        model.configureCamera(limits: try #require(DioramaCameraLimits(distance: 0.5...2, pitchDegrees: 0...60)), transition: .immediate, reduceMotion: true)
        model.controlState.navigation.setPitch(80)
        #expect(abs(model.resolvedCamera.pitch.degrees - 60) < 0.001)
        model.controlState.navigation.togglePerspective()
        #expect(abs(model.resolvedCamera.pitch.degrees) < 0.001)
        #expect(model.cameraMotion == nil)
        #expect(model.homeCamera == home)
        model.enabledGestures = []
        #expect(!model.controlState.canFaceNorth)
        #expect(!model.controlState.navigation.canPitch)
        #expect(!model.controlState.navigation.canFit)
        #expect(!model.performInput(.overhead))
    }
    @Test("Subthreshold and disabled-axis motion cannot steal an animated camera")
    func zeroInputPreservesOwnership() async {
        let model = await loadedModel(ControlsTilesProvider())
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        _ = proxy.setCamera(.init(heading: .degrees(100), distance: 2), transition: .easeInOut(duration: 4))
        model.enabledGestures = [.heading]
        model.primaryDrag(dx: 0, dy: 0)
        model.orbitInput(headingDegrees: 0, pitchDegrees: 10)
        #expect(model.cameraMotion != nil)
        model.orbitInput(headingDegrees: 1, pitchDegrees: 0)
        #expect(model.cameraMotion == nil)
    }
    @Test(.timeLimit(.minutes(1)))
    func wheelObservationEndsAndDoesNotSuppressLaterDrag() async {
        let model = await loadedModel(ControlsTilesProvider())
        let events = AsyncStream<DioramaCameraChangeContext>.makeStream()
        model.cameraObservation.action = DioramaCameraObservationAction(frequency: .onEnd) { events.continuation.yield($0) }
        var iterator = events.stream.makeAsyncIterator()
        #expect(model.zoomInput(1, isWheel: true, target: .camera))
        let wheelEnd = await iterator.next()
        #expect(wheelEnd?.phase == .ended)
        model.secondaryDrag(dx: 10, dy: 0)
        model.endInteraction(.drag)
        let dragEnd = await iterator.next()
        #expect(dragEnd?.phase == .ended)
        events.continuation.finish()
    }

    @Test func controlInsetsFollowAlignment() {
        let size = CGSize(width: 120, height: 250)
        let left = DioramaControlsLayout.insets(size: size, alignment: .topLeading)
        let right = DioramaControlsLayout.insets(size: size, alignment: .topTrailing)
        #expect(left.leading == 120 && left.trailing == 0)
        #expect(right.trailing == 120 && right.leading == 0)
    }
    @Test("Queued camera binding callbacks read the latest value and retain newer app requests")
    func bindingReadbackDoesNotCancelItsAnimation() async {
        let model = await loadedModel(ControlsTilesProvider())
        var bound = DioramaCameraPosition.camera(model.resolvedCamera)
        model.positionBinding = Binding(get: { bound }, set: { bound = $0 })
        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.cameraClock = { start }
        let proxy = DioramaCameraProxy(host: model.cameraHost)
        _ = proxy.setCamera(.init(pitch: .zero, distance: 2), transition: .easeInOut(duration: 2))
        model.advanceAnimation(at: start.addingTimeInterval(0.1))
        let queuedSnapshot = bound
        model.advanceAnimation(at: start.addingTimeInterval(0.2))
        #expect(bound != queuedSnapshot)
        model.synchronizeCameraBinding()
        #expect(model.cameraMotion != nil)
        let requested = DioramaCameraPosition.camera(DioramaCamera(heading: .degrees(90), pitch: .degrees(30), distance: 1))
        bound = requested
        model.advanceAnimation(at: start.addingTimeInterval(0.3))
        #expect(bound == requested)
        model.synchronizeCameraBinding()
        #expect(abs(model.resolvedCamera.heading.degrees - 90) < 0.001)
        bound = .camera(DioramaCamera(distance: -1))
        model.synchronizeCameraBinding()
        model.orbitInput(headingDegrees: 5, pitchDegrees: 0)
        #expect(bound.camera?.isValid == true)
        #expect(abs((bound.camera?.heading.degrees ?? 0) - 95) < 0.001)
        bound = .camera(DioramaCamera(distance: .nan))
        model.synchronizeCameraBinding()
        model.orbitInput(headingDegrees: 5, pitchDegrees: 0)
        #expect(bound.camera?.isValid == true)
        #expect(abs((bound.camera?.heading.degrees ?? 0) - 100) < 0.001)
    }
    #endif
}
