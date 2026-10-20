import CoreLocation
import Foundation
import SwiftUI
import Testing
import simd
@testable import Maquette

/// Every fetch is released explicitly, including obsolete requests that ignore cancellation.
private actor NavigationTilesProvider: Tiles3DProvider {
    nonisolated let attribution = "Navigation fixture"
    nonisolated let sourceID: Tiles3DSourceID? = Tiles3DSourceID("navigation-fixture")
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
        Issue.record("An empty tileset must never request tile content")
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

    func fail(_ index: Int) {
        requests.removeValue(forKey: index)?.resume(throwing: DioramaError.networkFailure(message: "obsolete"))
    }

    func requestCount() -> Int { count }
}

@MainActor
private final class NavigationCompletion {
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func finish() { completed = true; waiter?.resume(); waiter = nil }
    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@Suite("Geographic navigation")
@MainActor
struct DioramaNavigationTests {
    private static let origin = Coordinate(latitude: 36, longitude: -112)
    private static func position(_ radius: Double = 1_000, longitude: Double = -112) -> DioramaGroundPosition {
        DioramaGroundPosition(region: DioramaRegion(center: Coordinate(latitude: 36, longitude: longitude), radius: radius))
    }
    private func store(_ provider: NavigationTilesProvider) -> DioramaStore {
        DioramaStore(configuration: DioramaConfiguration(
            center: Self.origin.clLocationCoordinate, radiusMeters: 1_000,
            presentation: .photorealistic(provider: provider)
        ))
    }
    private func load(_ store: DioramaStore, provider: NavigationTilesProvider) async {
        let task = Task { await store.load() }
        await provider.waitForRequests(1)
        await provider.succeed(0)
        await task.value
    }

    @Test("A load released after reset cannot restore its scene or projection")
    func resetInvalidatesSuspendedLoad() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let old = Task { await store.load() }
        await provider.waitForRequests(1)
        store.reset()
        let generation = store.loadGeneration
        await provider.succeed(0)
        await old.value
        #expect(store.loadingState == .idle)
        #expect(store.dioramaEntity == nil)
        #expect(store.projection == nil)
        #expect(store.tilesAttribution == nil)
        #expect(store.loadGeneration == generation)
    }

    @Test("An obsolete success cannot replace the newer scene", arguments: [false, true])
    func newestLoadWins(staleFails: Bool) async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let old = Task { await store.load() }
        await provider.waitForRequests(1)
        store.reset()
        store.configuration.center = CLLocationCoordinate2D(latitude: 51, longitude: 10)
        store.configuration.radiusMeters = 4_000
        let current = Task { await store.load() }
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await current.value
        let entity = store.dioramaEntity
        #expect(store.loadingState == .loaded)
        if staleFails { await provider.fail(0) } else { await provider.succeed(0) }
        await old.value
        #expect(store.loadingState == .loaded)
        #expect(store.dioramaEntity === entity)
        #expect(abs(store.visibleGroundRegion.center.latitude - 51) < 0.00001)
        #expect(store.visibleGroundRegion.radius == 4_000)
    }

    @Test("Only the latest absolute ground command applies content and completion")
    func obsoleteCommandCannotApplyCallbacks() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let controller = DioramaNavigationController()
        let completion = NavigationCompletion()
        var obsoleteCallbacks = 0
        var currentContentCalls = 0
        controller.applyRequest(Self.position(2_000), store: store, content: {
            obsoleteCallbacks += 1
            return nil
        }, afterLoad: { obsoleteCallbacks += 1 })
        await provider.waitForRequests(1)
        controller.applyRequest(Self.position(8_000, longitude: 10), store: store, content: {
            currentContentCalls += 1
            return nil
        }, afterLoad: { completion.finish() })
        await provider.waitForRequests(2)
        await provider.succeed(1)
        await completion.wait()
        let currentEntity = store.dioramaEntity
        await provider.succeed(0)
        // The obsolete fetch has resumed; yielding lets its cancelled command finish its guard.
        for _ in 0..<10 { await Task.yield() }
        #expect(obsoleteCallbacks == 0)
        #expect(currentContentCalls == 1)
        #expect(store.dioramaEntity === currentEntity)
        #expect(store.configuration.radiusMeters == 8_000)
        #expect(store.configuration.center.longitude == 10)
        #expect(store.configuration.usesGeographicAnchor)
        controller.invalidateCommand()
    }

    @Test("A command reports its applied result even when it equals the requested value")
    func commandPublishesMatchingRequest() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let controller = DioramaNavigationController()
        let completion = NavigationCompletion()
        var contexts: [DioramaNavigationContext] = []
        controller.action = DioramaNavigationAction(frequency: .continuous, action: {
            contexts.append($0)
        })
        let request = DioramaGroundPosition(region: DioramaRegion(
            center: Coordinate(latitude: 0, longitude: 0), radius: 2_000
        ))
        controller.applyRequest(request, store: store, content: { nil }, afterLoad: { completion.finish() })
        await provider.waitForRequests(1)
        await provider.succeed(0)
        await completion.wait()
        #expect(contexts.count == 1)
        #expect(contexts.first?.position == request)
        #expect(contexts.first?.phase == .changing)
        #expect(contexts.first?.origin == .programmatic)
        controller.invalidateCommand()
    }

    @Test("User read-back updates the binding without issuing a new load")
    func bindingReadbackDoesNotReload() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        await load(store, provider: provider)
        let controller = DioramaNavigationController()
        var bound = Self.position()
        controller.binding = Binding(get: { bound }, set: { bound = $0 })
        controller.interactionBegan()
        controller.publish(from: store)
        #expect(bound.positionedByUser)
        #expect(controller.lastApplied == bound)
        let generation = store.loadGeneration
        controller.applyRequest(bound, store: store, content: {
            Issue.record("Read-back must not reapply content")
            return nil
        }, afterLoad: { Issue.record("Read-back must not reload") })
        for _ in 0..<10 { await Task.yield() }
        #expect(store.loadGeneration == generation)
        #expect(await provider.requestCount() == 1)
        controller.invalidateCommand()
    }

    @Test("Continuous observation reports applied ground and camera, then a single settled value")
    func continuousCallbackIncludesCameraAndProvenance() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        await load(store, provider: provider)
        let controller = DioramaNavigationController()
        let completion = NavigationCompletion()
        let camera = DioramaCamera(heading: .degrees(-(25)), pitch: .degrees(90 - (45)), distance: 1.5)
        controller.camera = { camera }
        var contexts: [DioramaNavigationContext] = []
        controller.action = DioramaNavigationAction(frequency: .continuous, action: {
            contexts.append($0)
            if $0.phase == .ended { completion.finish() }
        })
        controller.publish(from: store)
        controller.publish(from: store)
        #expect(contexts.count == 1)
        #expect(contexts.first?.phase == .changing)
        #expect(contexts.first?.origin == .programmatic)
        #expect(contexts.first?.camera == camera)
        #expect(contexts.first?.position.positionedByUser == false)
        await completion.wait()
        #expect(contexts.map(\.phase) == [.changing, .ended])
        #expect(contexts.last?.position == contexts.first?.position)
        controller.invalidateCommand()
    }

    @Test("End-only observation waits for interaction and transition to settle")
    func endCallbackWaitsForSettle() async throws {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        await load(store, provider: provider)
        let controller = DioramaNavigationController()
        var contexts: [DioramaNavigationContext] = []
        let completion = NavigationCompletion()
        var transitioning = true
        controller.isTransitioning = { transitioning }
        controller.action = DioramaNavigationAction(frequency: .onEnd, action: {
            contexts.append($0)
            completion.finish()
        })
        controller.interactionBegan()
        controller.publish(from: store)
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.isEmpty)
        controller.interactionEnded(store: store)
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.isEmpty)
        transitioning = false
        await completion.wait()
        #expect(contexts.count == 1)
        #expect(contexts.first?.phase == .ended)
        #expect(contexts.first?.origin == .userInteraction)
        #expect(contexts.first?.position.positionedByUser == true)
        #expect(contexts.first?.camera == nil)
        controller.invalidateCommand()
    }

    @Test("Camera end observation waits for the gesture and globe transition")
    func cameraEndCallbackWaitsForSettle() async throws {
        let observation = DioramaCameraObservation()
        var contexts: [DioramaCameraChangeContext] = []
        let completion = NavigationCompletion()
        var transitioning = true
        observation.isTransitioning = { transitioning }
        observation.action = DioramaCameraObservationAction(frequency: .onEnd, action: {
            contexts.append($0)
            completion.finish()
        })
        let first = DioramaCamera(heading: .degrees(-(10)), pitch: .degrees(90 - (45)), distance: 1.5)
        let final = DioramaCamera(heading: .degrees(-(20)), pitch: .degrees(90 - (45)), distance: 1.5)
        observation.began()
        observation.changed(first, origin: .userInteraction)
        observation.changed(final, origin: .userInteraction)
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.isEmpty)
        observation.ended()
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.isEmpty)
        transitioning = false
        await completion.wait()
        #expect(contexts.count == 1)
        #expect(contexts.first?.camera == final)
        #expect(contexts.first?.phase == .ended)
        #expect(contexts.first?.origin == .userInteraction)
    }

    @Test("Continuous camera observation suppresses duplicate values and ends programmatic moves")
    func continuousCameraObservation() async {
        let observation = DioramaCameraObservation()
        let completion = NavigationCompletion()
        var contexts: [DioramaCameraChangeContext] = []
        observation.action = DioramaCameraObservationAction(frequency: .continuous, action: {
            contexts.append($0)
            if $0.phase == .ended { completion.finish() }
        })
        let camera = DioramaCamera(heading: .degrees(-(10)), pitch: .degrees(90 - (45)), distance: 1.5)
        observation.changed(camera, origin: .programmatic)
        observation.changed(camera, origin: .programmatic)
        #expect(contexts.count == 1)
        #expect(contexts.first?.phase == .changing)
        await completion.wait()
        #expect(contexts.map(\.phase) == [.changing, .ended])
        #expect(contexts.allSatisfy { $0.camera == camera && $0.origin == .programmatic })
    }

    @Test("Automatic loading provisions pan ground while preserving an explicit legacy margin")
    func loadingPolicyResolution() {
        let style = DioramaStyle.standard()
        #expect(style.resolving(.automatic, interactionModes: [.pan]).panRange == 0.5)
        #expect(style.resolving(.automatic, interactionModes: [.rotate, .zoom]).panRange == 0)
        let legacy = DioramaStyle.standard(panRange: 0.8)
        #expect(legacy.resolving(.automatic, interactionModes: [.pan]).panRange == 0.8)
        #expect(legacy.resolving(.automatic, interactionModes: [.rotate]).panRange == 0.8)
        #expect(legacy.resolving(.prefetchMargin(0), interactionModes: .all).panRange == 0)
        #expect(legacy.resolving(.prefetchMargin(0.6), interactionModes: .all).panRange == 0.6)
        for invalid: Float in [-1, .nan, .infinity, -.infinity] {
            #expect(legacy.resolving(.prefetchMargin(invalid), interactionModes: .all).panRange == 0)
        }
    }

    @Test("Ground navigation reports a repeated endpoint and waits for every active gesture")
    func repeatedGroundEndpointAndSimultaneousGestures() async throws {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        await load(store, provider: provider)
        let controller = DioramaNavigationController()
        let firstCompletion = NavigationCompletion()
        let secondCompletion = NavigationCompletion()
        var contexts: [DioramaNavigationContext] = []
        controller.action = DioramaNavigationAction(frequency: .onEnd, action: {
            contexts.append($0)
            if contexts.count == 1 { firstCompletion.finish() }
            if contexts.count == 2 { secondCompletion.finish() }
        })
        controller.interactionBegan()
        controller.publish(from: store)
        controller.interactionEnded(store: store)
        await firstCompletion.wait()
        #expect(contexts.count == 1)
        controller.interactionBegan(.drag)
        controller.interactionBegan(.zoom)
        store.configuration.radiusMeters = 2_000
        controller.publish(from: store)
        store.configuration.radiusMeters = 1_000
        controller.publish(from: store)
        controller.interactionEnded(store: store, source: .drag)
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.count == 1)
        controller.interactionEnded(store: store, source: .zoom)
        await secondCompletion.wait()
        #expect(contexts.count == 2)
        #expect(contexts.first?.position == contexts.last?.position)
        #expect(contexts.allSatisfy { $0.phase == .ended && $0.origin == .userInteraction })
        controller.invalidateCommand()
    }

    @Test("Camera observation reports a repeated endpoint and waits for every active gesture")
    func repeatedCameraEndpointAndSimultaneousGestures() async throws {
        let observation = DioramaCameraObservation()
        let firstCompletion = NavigationCompletion()
        let secondCompletion = NavigationCompletion()
        var contexts: [DioramaCameraChangeContext] = []
        observation.action = DioramaCameraObservationAction(frequency: .onEnd, action: {
            contexts.append($0)
            if contexts.count == 1 { firstCompletion.finish() }
            if contexts.count == 2 { secondCompletion.finish() }
        })
        let start = DioramaCamera(heading: .degrees(-(10)), pitch: .degrees(90 - (45)), distance: 1.5)
        let away = DioramaCamera(heading: .degrees(-(20)), pitch: .degrees(90 - (45)), distance: 1.5)
        observation.began()
        observation.changed(start, origin: .userInteraction)
        observation.ended()
        await firstCompletion.wait()
        #expect(contexts.count == 1)
        observation.began(.drag)
        observation.began(.zoom)
        observation.changed(away, origin: .userInteraction)
        observation.changed(start, origin: .userInteraction)
        observation.ended(.drag)
        try await Task.sleep(for: .milliseconds(200))
        #expect(contexts.count == 1)
        observation.ended(.zoom)
        await secondCompletion.wait()
        #expect(contexts.count == 2)
        #expect(contexts.first?.camera == contexts.last?.camera)
        #expect(contexts.allSatisfy { $0.phase == .ended && $0.origin == .userInteraction })
    }

    @Test("A building visibility change leaves a pending ground command running")
    func visibilityChangeDoesNotCancelGroundCommand() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        store.configuration.buildings = .standard
        let controller = DioramaNavigationController()
        let completion = NavigationCompletion()
        controller.applyRequest(Self.position(2_000), store: store, content: { nil }, afterLoad: { completion.finish() })
        await provider.waitForRequests(1)
        let configuration = store.configuration
        var style = DioramaStyle(configuration: configuration)
        style.buildings?.isVisible = false
        let key = DioramaViewInputs.ReloadKey(
            region: DioramaRegion(center: Coordinate(configuration.center), radius: configuration.radiusMeters),
            shape: configuration.shape, physicalSize: configuration.physicalSize, style: style
        )
        var reloadCount = 0
        DioramaLiveInputs.applyReloadKey(key, store: store, content: nil, beforeReload: {
            reloadCount += 1
            controller.invalidateCommand()
        }, afterLoad: { Issue.record("Visibility must not reload the scene") })
        #expect(reloadCount == 0)
        #expect(store.configuration.buildings?.isVisible == false)
        await provider.succeed(0)
        await completion.wait()
        #expect(store.loadingState == .loaded)
        #expect(await provider.requestCount() == 1)
        controller.invalidateCommand()
    }

    @Test("A navigation-owned visible region does not turn building visibility into a reload")
    func visibilityChangeIgnoresSubstitutedNavigationRegion() {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        store.configuration.buildings = .standard
        let initial = store.configuration
        let generation = store.loadGeneration
        var style = DioramaStyle(configuration: initial)
        style.buildings?.isVisible = false
        let key = DioramaViewInputs.ReloadKey(
            region: DioramaRegion(center: Coordinate(latitude: 52, longitude: 10), radius: 8_000),
            shape: initial.shape, physicalSize: initial.physicalSize, style: style
        )
        var reloadCount = 0
        DioramaLiveInputs.applyReloadKey(key, store: store, content: nil,
            usesGeographicAnchor: true, beforeReload: { reloadCount += 1 },
            afterLoad: { Issue.record("Visibility must not reload navigation-owned ground") })
        #expect(reloadCount == 0)
        #expect(store.loadGeneration == generation)
        #expect(store.configuration.radiusMeters == initial.radiusMeters)
        #expect(Coordinate(store.configuration.center) == Coordinate(initial.center))
        #expect(store.configuration.buildings?.isVisible == false)
    }

    @Test("Legacy live regions still apply geographic changes")
    func legacyReloadAppliesChangedRegion() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let completion = NavigationCompletion()
        let target = Self.position(8_000, longitude: 10).region
        let key = DioramaViewInputs.ReloadKey(
            region: target, shape: store.configuration.shape,
            physicalSize: store.configuration.physicalSize, style: DioramaStyle(configuration: store.configuration)
        )
        var reloadCount = 0
        DioramaLiveInputs.applyReloadKey(key, store: store, content: nil,
            usesGeographicAnchor: false, beforeReload: { reloadCount += 1 },
            afterLoad: { completion.finish() })
        await provider.waitForRequests(1)
        #expect(reloadCount == 1)
        #expect(store.configuration.radiusMeters == target.radius)
        #expect(Coordinate(store.configuration.center) == target.center)
        await provider.succeed(0)
        await completion.wait()
        #expect(store.loadingState == .loaded)
    }

    @Test("A suspended live reload applies the newest content after the fetch")
    func liveReloadUsesLatestContent() async throws {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let completion = NavigationCompletion()
        let old = DioramaContentGroup {
            DioramaMarker("Old", coordinate: Self.origin, id: "old")
        }
        // Removing the marker while loading must survive completion. An empty replacement also
        // keeps this synchronization test independent of RealityKit's GPU-backed pin geometry.
        let current = DioramaContentGroup(items: [])
        var latest = old
        var latestReads = 0
        let key = DioramaViewInputs.ReloadKey(
            region: Self.position(2_000).region, shape: store.configuration.shape,
            physicalSize: store.configuration.physicalSize, style: DioramaStyle(configuration: store.configuration)
        )
        DioramaLiveInputs.applyReloadKey(key, store: store, content: old, latestContent: {
            latestReads += 1
            return latest
        }, afterLoad: { completion.finish() })
        await provider.waitForRequests(1)
        latest = current
        await provider.succeed(0)
        await completion.wait()
        let entity = try #require(store.dioramaEntity as? DioramaEntity)
        #expect(latestReads == 1)
        #expect(entity.markerEntities["old"] == nil)
        #expect(entity.markerEntities.isEmpty)
    }

    @Test("Taking ownership from a globe relocation clears its hold and animation clock")
    func cancellingGlobeRelocationResetsTransition() {
        let conductor = GlobeHandoffConductor()
        conductor.transition.beginHold()
        conductor.lastTransitionDate = Date()
        conductor.cancelRelocation()
        #expect(!conductor.transition.isHolding)
        #expect(!conductor.transition.isAnimating)
        #expect(conductor.transition.progress == 0)
        #expect(conductor.lastTransitionDate == nil)
    }

    #if os(iOS) || os(macOS)
    @Test("Startup-only navigation survives a second style reload while the first fetch is pending")
    func rapidStyleReloadsPreserveNavigatedGround() async {
        let provider = NavigationTilesProvider()
        var configuration = store(provider).configuration
        configuration.center = CLLocationCoordinate2D(latitude: 51, longitude: 10)
        configuration.radiusMeters = 9_000
        let model = OrbitDioramaModel(configuration: configuration, content: nil)
        await load(model.store, provider: provider)
        model.navigation.preservesGround = true
        let staleStartupRegion = Self.position(1_000).region
        let style = DioramaStyle(configuration: configuration)
        let first = DioramaViewInputs.ReloadKey(
            region: staleStartupRegion, shape: .circular, physicalSize: 0.7, style: style
        )
        let second = DioramaViewInputs.ReloadKey(
            region: staleStartupRegion, shape: .circular, physicalSize: 0.6, style: style
        )
        model.applyReloadKey(first)
        await provider.waitForRequests(2)
        #expect(model.store.projection == nil)
        let completion = NavigationCompletion()
        model.store.groundDidChange = {
            if model.store.loadingState == .loaded && model.store.configuration.physicalSize == 0.6 {
                completion.finish()
            }
        }
        model.applyReloadKey(second)
        await provider.waitForRequests(3)
        await provider.succeed(2)
        await completion.wait()
        let currentEntity = model.store.dioramaEntity
        #expect(model.store.configuration.radiusMeters == 9_000)
        #expect(abs(model.store.configuration.center.latitude - 51) < 0.000001)
        #expect(abs(model.store.configuration.center.longitude - 10) < 0.000001)
        #expect(model.store.configuration.physicalSize == 0.6)
        await provider.succeed(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.store.dioramaEntity === currentEntity)
        #expect(model.store.configuration.radiusMeters == 9_000)
        model.store.groundDidChange = nil
    }
    #endif

    @Test("Queued live keys discard obsolete work before it starts fetching")
    func queuedLiveReloadKeysUseLatestOnly() async {
        let provider = NavigationTilesProvider()
        let store = store(provider)
        let completion = NavigationCompletion()
        let style = DioramaStyle(configuration: store.configuration)
        let first = DioramaViewInputs.ReloadKey(
            region: Self.position(2_000).region, shape: .circular, physicalSize: 0.7, style: style
        )
        let second = DioramaViewInputs.ReloadKey(
            region: Self.position(4_000, longitude: 10).region, shape: .hexagonal, physicalSize: 0.6, style: style
        )
        DioramaLiveInputs.applyReloadKey(first, store: store, content: nil,
            afterLoad: { Issue.record("An obsolete queued reload must not finish") })
        DioramaLiveInputs.applyReloadKey(second, store: store, content: nil,
            afterLoad: { completion.finish() })
        await provider.waitForRequests(1)
        #expect(await provider.requestCount() == 1)
        #expect(store.configuration.radiusMeters == 4_000)
        #expect(store.configuration.center.longitude == 10)
        #expect(store.configuration.physicalSize == 0.6)
        #expect(store.configuration.shape == .hexagonal)
        await provider.succeed(0)
        await completion.wait()
        #expect(store.loadingState == .loaded)
        #expect(await provider.requestCount() == 1)
    }

    @Test("WGS84 inverse preserves the ground coordinate at high latitude and across the dateline")
    func ellipsoidInverseRoundTrips() throws {
        let pairs: [(Coordinate, Coordinate)] = [
            (Coordinate(latitude: 36, longitude: -112), Coordinate(latitude: 36.05, longitude: -111.95)),
            (Coordinate(latitude: 80, longitude: 20), Coordinate(latitude: 80.1, longitude: 20.4)),
            (Coordinate(latitude: 10, longitude: 179.9), Coordinate(latitude: 10.05, longitude: -179.9)),
        ]
        for (origin, target) in pairs {
            let converter = ECEFConverter(origin: origin.clLocationCoordinate)
            let local = converter.local(for: target)
            let result = try #require(converter.coordinate(atHorizontalPoint: SIMD2(Double(local.x), Double(local.z))))
            #expect(abs(result.latitude - target.latitude) < 0.000001)
            #expect(abs(result.longitude - target.longitude) < 0.000001)
        }
        let converter = ECEFConverter(origin: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        #expect(converter.coordinate(atHorizontalPoint: SIMD2(7_000_000, 0)) == nil)
    }
}
