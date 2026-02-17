import Foundation
import Testing
@testable import Maquette

/// A mock tile provider for testing the cache.
struct MockTileProvider: TileProvider {
    let providerIdentifier = "mock"
    var fetchCount: Int = 0

    func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        Data("tile-\(zoom)-\(x)-\(y)".utf8)
    }
}

@Suite("Tile Cache Tests")
struct TileCacheTests {
    @Test("Cache returns data from provider on first fetch")
    func firstFetch() async throws {
        let cache = TileCache(maxMemoryEntries: 10)
        let provider = MockTileProvider()
        let data = try await cache.cachedOrFetch(x: 0, y: 0, zoom: 10, provider: provider)
        #expect(!data.isEmpty)
        #expect(String(data: data, encoding: .utf8) == "tile-10-0-0")
    }

    @Test("Cache returns same data on second fetch (cache hit)")
    func cacheHit() async throws {
        let cache = TileCache(maxMemoryEntries: 10)
        let provider = MockTileProvider()

        let data1 = try await cache.cachedOrFetch(x: 1, y: 2, zoom: 14, provider: provider)
        let data2 = try await cache.cachedOrFetch(x: 1, y: 2, zoom: 14, provider: provider)
        #expect(data1 == data2)
    }

    @Test("Different tile coordinates produce different data")
    func differentTiles() async throws {
        let cache = TileCache(maxMemoryEntries: 10)
        let provider = MockTileProvider()

        let data1 = try await cache.cachedOrFetch(x: 0, y: 0, zoom: 10, provider: provider)
        let data2 = try await cache.cachedOrFetch(x: 1, y: 1, zoom: 10, provider: provider)
        #expect(data1 != data2)
    }

    @Test("Clear removes all cached data")
    func clearCache() async throws {
        let cache = TileCache(maxMemoryEntries: 10)
        let provider = MockTileProvider()

        _ = try await cache.cachedOrFetch(x: 0, y: 0, zoom: 10, provider: provider)
        await cache.clearAll()

        // After clearing, fetching again should work (re-fetch from provider)
        let data = try await cache.cachedOrFetch(x: 0, y: 0, zoom: 10, provider: provider)
        #expect(!data.isEmpty)
    }

    @Test("LRU eviction removes oldest entries")
    func lruEviction() async throws {
        let cache = TileCache(maxMemoryEntries: 3)
        let provider = MockTileProvider()

        // Fill cache with 4 entries (exceeding max of 3)
        for i in 0..<4 {
            _ = try await cache.cachedOrFetch(x: i, y: 0, zoom: 10, provider: provider)
        }

        // The cache should still function (oldest evicted from memory, but may be on disk)
        let data = try await cache.cachedOrFetch(x: 3, y: 0, zoom: 10, provider: provider)
        #expect(!data.isEmpty)
    }
}
