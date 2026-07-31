import Foundation
import Testing
@testable import Maquette

@Suite("Terrain Tile Provider Tests")
struct TerrainTileProviderTests {

    @Test("Successful tile fetch returns data")
    func successfulFetch() async throws {
        let tileData = Data("fake-png-data".utf8)
        let mock = MockHTTPClient(responses: [
            "s3.amazonaws.com/elevation-tiles-prod/terrarium/12/100/200.png":
                .init(data: tileData, statusCode: 200)
        ])
        let provider = TerrainTileProvider(httpClient: mock)

        let result = try await provider.fetchTile(x: 100, y: 200, zoom: 12)
        #expect(result == tileData)
    }

    @Test("Provider identifier is correct")
    func providerIdentifier() {
        #expect(TerrainTileProvider().providerIdentifier == "terrarium")
    }

    @Test("A missing tile throws tileNotFound")
    func missingTileThrows() async {
        let mock = MockHTTPClient(responses: [
            "s3.amazonaws.com": .init(statusCode: 404)
        ])
        let provider = TerrainTileProvider(httpClient: mock)

        do {
            _ = try await provider.fetchTile(x: 1, y: 2, zoom: 3)
            Issue.record("Expected tileNotFound error")
        } catch let error as DioramaError {
            if case .tileNotFound(let x, let y, let zoom) = error {
                #expect(x == 1 && y == 2 && zoom == 3)
            } else {
                Issue.record("Expected tileNotFound, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
