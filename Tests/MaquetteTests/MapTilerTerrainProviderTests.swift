import Foundation
import Testing
@testable import Maquette

@Suite("MapTiler Terrain Provider Tests")
struct MapTilerTerrainProviderTests {

    @Test("Successful tile fetch returns data")
    func successfulFetch() async throws {
        let tileData = Data("fake-webp-data".utf8)
        let mock = MockHTTPClient(responses: [
            "api.maptiler.com": .init(data: tileData, statusCode: 200)
        ])
        let provider = MapTilerTerrainProvider(apiKey: "test-key", httpClient: mock)

        let result = try await provider.fetchTile(x: 100, y: 200, zoom: 12)
        #expect(result == tileData)
    }

    @Test("Provider identifier is correct")
    func providerIdentifier() {
        let provider = MapTilerTerrainProvider(apiKey: "test-key")
        #expect(provider.providerIdentifier == "maptiler-terrain")
    }

    @Test("401 response throws authenticationFailed")
    func authenticationFailed() async {
        let mock = MockHTTPClient(responses: [
            "api.maptiler.com": .init(statusCode: 401)
        ])
        let provider = MapTilerTerrainProvider(apiKey: "bad-key", httpClient: mock)

        do {
            _ = try await provider.fetchTile(x: 0, y: 0, zoom: 0)
            Issue.record("Expected authenticationFailed error")
        } catch let error as DioramaError {
            if case .authenticationFailed(let providerName) = error {
                #expect(providerName == "MapTiler")
            } else {
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("429 response throws rateLimited")
    func rateLimited() async {
        let mock = MockHTTPClient(responses: [
            "api.maptiler.com": .init(statusCode: 429)
        ])
        let provider = MapTilerTerrainProvider(apiKey: "test-key", httpClient: mock)

        do {
            _ = try await provider.fetchTile(x: 0, y: 0, zoom: 0)
            Issue.record("Expected rateLimited error")
        } catch let error as DioramaError {
            if case .rateLimited(let providerName, _) = error {
                #expect(providerName == "MapTiler")
            } else {
                Issue.record("Expected rateLimited, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
