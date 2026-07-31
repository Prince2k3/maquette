import Foundation
import Testing
@testable import Maquette

@Suite("Cesium Ion 3D Provider Tests")
struct CesiumIonTiles3DProviderTests {

    private func sampleEndpointResponse() -> Data {
        """
        {
            "url": "https://assets.cesium.com/1234",
            "accessToken": "short-lived-token-xyz",
            "type": "3DTILES"
        }
        """.data(using: .utf8)!
    }

    private func sampleTilesetJSON() -> Data {
        """
        {
            "asset": { "version": "1.1" },
            "geometricError": 50.0,
            "root": {
                "boundingVolume": { "sphere": [0, 0, 0, 500] },
                "geometricError": 50.0
            }
        }
        """.data(using: .utf8)!
    }

    @Test("Two-step auth flow succeeds")
    func twoStepAuthSuccess() async throws {
        let mock = MockHTTPClient(responses: [
            "api.cesium.com": .init(data: sampleEndpointResponse(), statusCode: 200),
            "assets.cesium.com": .init(data: sampleTilesetJSON(), statusCode: 200)
        ])
        let provider = CesiumIonTiles3DProvider(
            accessToken: "test-token",
            assetId: 2275207,
            httpClient: mock
        )

        let data = try await provider.fetchTileset()
        let tileset = try JSONDecoder().decode(TilesetJSON.self, from: data)
        #expect(tileset.asset.version == "1.1")
        #expect(tileset.geometricError == 50.0)
    }

    @Test("401 on endpoint throws authenticationFailed")
    func authenticationFailed() async {
        let mock = MockHTTPClient(responses: [
            "api.cesium.com": .init(statusCode: 401)
        ])
        let provider = CesiumIonTiles3DProvider(
            accessToken: "bad-token",
            assetId: 2275207,
            httpClient: mock
        )

        do {
            _ = try await provider.fetchTileset()
            Issue.record("Expected authenticationFailed error")
        } catch let error as DioramaError {
            if case .authenticationFailed(let name) = error {
                #expect(name == "Cesium")
            } else {
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Fetch tile content without endpoint throws sessionExpired")
    func fetchContentWithoutEndpoint() async {
        let mock = MockHTTPClient(responses: [:])
        let provider = CesiumIonTiles3DProvider(
            accessToken: "test-token",
            assetId: 2275207,
            httpClient: mock
        )

        do {
            _ = try await provider.fetchTileContent(uri: "some/tile.glb")
            Issue.record("Expected sessionExpired error")
        } catch let error as DioramaError {
            if case .sessionExpired = error {
                // Expected
            } else {
                Issue.record("Expected sessionExpired, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Attribution is Cesium")
    func attribution() {
        let provider = CesiumIonTiles3DProvider(accessToken: "token", assetId: 1)
        #expect(provider.attribution == "Cesium")
    }
}
