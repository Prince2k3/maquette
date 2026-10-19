import CoreLocation
import Foundation
import Testing
@testable import Maquette

@Suite("3D Tiles Source Identity")
struct Tiles3DProviderIdentityTests {
    private struct Source: Tiles3DProvider {
        let sourceID: Tiles3DSourceID?
        var attribution: String { "Shared attribution" }
        func fetchTileset() async throws -> Data { Data("root".utf8) }
        func fetchTileContent(uri: String) async throws -> Data { Data(uri.utf8) }
    }

    private struct LegacySource: Tiles3DProvider {
        var attribution: String { "Shared attribution" }
        func fetchTileset() async throws -> Data { Data("root".utf8) }
        func fetchTileContent(uri: String) async throws -> Data { Data(uri.utf8) }
    }

    @Test("Different custom assets with the same attribution reload")
    func customAssets() {
        let first = DioramaStyle.photorealistic(provider: Source(sourceID: Tiles3DSourceID("asset-a")))
        let second = DioramaStyle.photorealistic(provider: Source(sourceID: Tiles3DSourceID("asset-b")))
        #expect(first != second)
    }

    @Test("Reconstructed styles for an unchanged source compare equal")
    func stableSource() {
        let first = DioramaStyle.photorealistic(provider: Source(sourceID: Tiles3DSourceID("asset", revision: "1")))
        let second = DioramaStyle.photorealistic(provider: Source(sourceID: Tiles3DSourceID("asset", revision: "1")))
        let revised = DioramaStyle.photorealistic(provider: Source(sourceID: Tiles3DSourceID("asset", revision: "2")))
        #expect(first == second)
        #expect(first != revised)
        #expect(Tiles3DSourceID("ab", revision: "c") != Tiles3DSourceID("a", revision: "bc"))
    }

    @Test("Built-in source identity includes assets and credentials")
    func builtinSources() {
        let google = DioramaStyle.photorealistic(provider: GoogleTiles3DProvider(apiKey: "key-a"))
        #expect(google == .photorealistic(provider: GoogleTiles3DProvider(apiKey: "key-a")))
        #expect(google != .photorealistic(provider: GoogleTiles3DProvider(apiKey: "key-b")))

        let cesium = DioramaStyle.photorealistic(provider: CesiumIonTiles3DProvider(accessToken: "token-a", assetId: 1))
        #expect(cesium == .photorealistic(provider: CesiumIonTiles3DProvider(accessToken: "token-a", assetId: 1)))
        #expect(cesium != .photorealistic(provider: CesiumIonTiles3DProvider(accessToken: "token-a", assetId: 2)))
        #expect(cesium != .photorealistic(provider: CesiumIonTiles3DProvider(accessToken: "token-b", assetId: 1)))
    }

    @Test("Legacy styles are reflexive and conservatively distinguish new constructions")
    func legacyIdentity() {
        let provider = LegacySource()
        let style = DioramaStyle.photorealistic(provider: provider)
        let copy = style
        #expect(style == style)
        #expect(style == copy)
        #expect(style != .photorealistic(provider: provider))

        // Live input comparison reconstructs the current style from the store configuration.
        let configuration = DioramaConfiguration(
            region: DioramaRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), radius: 100),
            shape: .hexagonal, physicalSize: 0.8, style: style
        )
        #expect(style == DioramaStyle(configuration: configuration))
    }

    @Test("Legacy identity wrapping preserves fetches and attribution")
    func legacyForwarding() async throws {
        let style = DioramaStyle.photorealistic(provider: LegacySource())
        guard case .photorealistic(let provider, _) = style.presentation else {
            Issue.record("Expected photorealistic presentation")
            return
        }
        #expect(provider.sourceID != nil)
        #expect(provider.attribution == "Shared attribution")
        #expect(try await provider.fetchTileset() == Data("root".utf8))
        #expect(try await provider.fetchTileContent(uri: "tile.glb") == Data("tile.glb".utf8))
    }

    @Test("Identity reflection does not contain raw credentials")
    func opaqueCredentials() throws {
        let provider = GoogleTiles3DProvider(apiKey: "private-google-test-key")
        let identity = try #require(provider.sourceID)
        #expect(!String(reflecting: identity).contains("private-google-test-key"))
    }
}
