import Foundation
import Testing
@testable import Maquette

@Suite("Google Tiles 3D Provider Tests")
struct GoogleTiles3DProviderTests {
    /// A cache in a throwaway location, so one test's root does not satisfy another's fetch.
    private func isolatedCache() -> RootTilesetCache {
        RootTilesetCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MaquetteRootCacheTests/\(UUID().uuidString)", isDirectory: true))
    }


    private func sampleTilesetJSON() -> Data {
        """
        {
            "asset": { "version": "1.1" },
            "geometricError": 100.0,
            "root": {
                "boundingVolume": { "sphere": [0, 0, 0, 1000] },
                "geometricError": 100.0,
                "content": { "uri": "tiles/root.glb" }
            },
            "session": "test-session-token-123"
        }
        """.data(using: .utf8)!
    }

    @Test("Fetch tileset succeeds with valid API key")
    func fetchTilesetSuccess() async throws {
        let mock = MockHTTPClient(responses: [
            "tile.googleapis.com": .init(data: sampleTilesetJSON(), statusCode: 200)
        ])
        let provider = GoogleTiles3DProvider(apiKey: "test-key", httpClient: mock, rootCache: isolatedCache())

        let tileset = try await provider.fetchTileset()
        #expect(tileset.asset.version == "1.1")
        #expect(tileset.geometricError == 100.0)
    }

    @Test("403 throws authenticationFailed")
    func authenticationFailed() async {
        let mock = MockHTTPClient(responses: [
            "tile.googleapis.com": .init(statusCode: 403)
        ])
        let provider = GoogleTiles3DProvider(apiKey: "bad-key", httpClient: mock)

        do {
            _ = try await provider.fetchTileset()
            Issue.record("Expected authenticationFailed error")
        } catch let error as DioramaError {
            if case .authenticationFailed(let name) = error {
                #expect(name == "Google")
            } else {
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("429 throws rateLimited")
    func rateLimited() async {
        let mock = MockHTTPClient(responses: [
            "tile.googleapis.com": .init(statusCode: 429)
        ])
        let provider = GoogleTiles3DProvider(apiKey: "test-key", httpClient: mock, rootCache: isolatedCache())

        do {
            _ = try await provider.fetchTileset()
            Issue.record("Expected rateLimited error")
        } catch let error as DioramaError {
            if case .rateLimited(let name, _) = error {
                #expect(name == "Google")
            } else {
                Issue.record("Expected rateLimited, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Attribution is Google")
    func attribution() {
        let provider = GoogleTiles3DProvider(apiKey: "key")
        #expect(provider.attribution == "Google")
    }
}
