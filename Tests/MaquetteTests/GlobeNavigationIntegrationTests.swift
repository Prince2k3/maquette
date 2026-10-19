import Foundation
import Testing
@testable import Maquette

private actor GlobeReturnProvider: Tiles3DProvider {
    nonisolated let attribution = "Globe return fixture"
    nonisolated let sourceID: Tiles3DSourceID? = Tiles3DSourceID("globe-return-fixture")
    private var count = 0
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func fetchTileset() async throws -> Data {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func fetchTileContent(uri: String) async throws -> Data {
        Issue.record("Empty fixture tilesets have no tile content")
        return Data()
    }

    func waitForRequests(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }

    func finish(_ index: Int, fails: Bool = false) {
        if fails {
            pending.removeValue(forKey: index)?.resume(throwing: DioramaError.networkFailure(message: "obsolete return"))
        } else {
            pending.removeValue(forKey: index)?.resume(returning: Data("""
            {"asset":{"version":"1.0"},"geometricError":0,"root":{
              "boundingVolume":{"sphere":[6378137,0,0,1]},"geometricError":0}}
            """.utf8))
        }
    }
}

@MainActor
private final class GlobeReturnCompletion {
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func finish() { finished = true; continuation?.resume(); continuation = nil }
    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@Suite("Globe return navigation integration")
@MainActor
struct GlobeNavigationIntegrationTests {
    private func preparedStore(_ provider: GlobeReturnProvider) async -> DioramaStore {
        let store = DioramaStore(configuration: DioramaConfiguration(
            center: .init(latitude: 0, longitude: 0), radiusMeters: 1000,
            presentation: .photorealistic(provider: provider)
        ))
        let load = Task { await store.load() }
        await provider.waitForRequests(1)
        await provider.finish(0)
        await load.value
        // The untextured globe is enough to exercise real docking and the full async return.
        store.installGlobe(GlobeEntity())
        store.steerGlobe(east: 100_000, north: 0)
        return store
    }

    @Test("A canceled globe return cannot apply content or release a newer command", arguments: [false, true])
    func supersededReturn(fails: Bool) async throws {
        let provider = GlobeReturnProvider()
        let store = await preparedStore(provider)
        let conductor = GlobeHandoffConductor()
        var obsoleteCallbacks = 0
        conductor.relocate(store: store, content: .empty, latestContent: {
            obsoleteCallbacks += 1
            return .empty
        }, afterLoad: { obsoleteCallbacks += 1 }, applyFrames: {})
        let oldTask = try #require(conductor.relocationTask)
        await provider.waitForRequests(2)
        #expect(conductor.transition.isHolding)

        conductor.cancelRelocation()
        let navigation = DioramaNavigationController()
        let completion = GlobeReturnCompletion()
        let destination = DioramaRegion(center: Coordinate(latitude: 20, longitude: 30), radius: 4000)
        navigation.applyRequest(DioramaGroundPosition(region: destination), store: store, content: { .empty }) {
            completion.finish()
        }
        await provider.waitForRequests(3)
        await provider.finish(2)
        await completion.wait()
        let currentEntity = store.dioramaEntity
        await provider.finish(1, fails: fails)
        await oldTask.value

        #expect(obsoleteCallbacks == 0)
        #expect(store.loadingState == .loaded)
        #expect(store.dioramaEntity === currentEntity)
        #expect(abs(store.visibleGroundRegion.center.latitude - destination.center.latitude) < 0.000001)
        #expect(abs(store.visibleGroundRegion.center.longitude - destination.center.longitude) < 0.000001)
        #expect(store.visibleGroundRegion.radius == destination.radius)
        #expect(!conductor.transition.isHolding)
        #expect(conductor.transition.progress == 0)
        navigation.invalidateCommand()
    }

    @Test("A successful globe return consumes current content and releases its own hold")
    func currentContentAtLanding() async throws {
        let provider = GlobeReturnProvider()
        let store = await preparedStore(provider)
        let landing = try #require(store.globeDock?.coordinate)
        let conductor = GlobeHandoffConductor()
        var contentChanged = false
        var sawCurrentContent = false
        var completions = 0
        conductor.relocate(store: store, content: .empty, latestContent: {
            sawCurrentContent = contentChanged
            return .empty
        }, afterLoad: { completions += 1 }, applyFrames: {})
        let task = try #require(conductor.relocationTask)
        await provider.waitForRequests(2)
        contentChanged = true
        await provider.finish(1)
        await task.value

        #expect(sawCurrentContent)
        #expect(completions == 1)
        #expect(!conductor.transition.isHolding)
        #expect(conductor.transition.isAnimating)
        #expect(abs(store.visibleGroundRegion.center.longitude - landing.longitude) < 0.000001)
        #expect(store.loadingState == .loaded)
        conductor.cancelRelocation()
    }
}
