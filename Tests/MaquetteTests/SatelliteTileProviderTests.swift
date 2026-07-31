import Foundation
import Testing
@testable import Maquette

@Suite("Satellite Tile Provider Tests")
struct SatelliteTileProviderTests {

    @Test("The template's placeholders become the requested tile")
    func templateSubstitution() async throws {
        let tileData = Data("fake-jpeg-data".utf8)
        let mock = MockHTTPClient(responses: [
            "server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/10/358/536":
                .init(data: tileData, statusCode: 200)
        ])
        let provider = SatelliteTileProvider(httpClient: mock)

        // ESRI's template is {z}/{y}/{x} — y before x.
        let result = try await provider.fetchTile(x: 536, y: 358, zoom: 10)
        #expect(result == tileData)
    }

    @Test("A custom template and identifier are honoured")
    func customTemplate() async throws {
        let tileData = Data("custom".utf8)
        let mock = MockHTTPClient(responses: [
            "tiles.example.com/5/1/2.png": .init(data: tileData, statusCode: 200)
        ])
        let provider = SatelliteTileProvider(
            urlTemplate: "https://tiles.example.com/{z}/{x}/{y}.png",
            identifier: "example",
            httpClient: mock
        )

        #expect(provider.providerIdentifier == "example")
        let result = try await provider.fetchTile(x: 1, y: 2, zoom: 5)
        #expect(result == tileData)
    }

    @Test("A non-2xx response throws tileNotFound")
    func failureThrows() async {
        let mock = MockHTTPClient(responses: [
            "server.arcgisonline.com": .init(statusCode: 500)
        ])
        let provider = SatelliteTileProvider(httpClient: mock)

        do {
            _ = try await provider.fetchTile(x: 4, y: 5, zoom: 6)
            Issue.record("Expected tileNotFound error")
        } catch let error as DioramaError {
            if case .tileNotFound(let x, let y, let zoom) = error {
                #expect(x == 4 && y == 5 && zoom == 6)
            } else {
                Issue.record("Expected tileNotFound, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
