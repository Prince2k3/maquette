import Foundation
import os

/// Actor-based tile cache providing both in-memory LRU and disk caching.
public actor TileCache {
    private var memoryCache: [String: CacheEntry] = [:]
    private var accessOrder: [String] = []
    private let maxMemoryEntries: Int
    private let diskCacheURL: URL?
    private let logger = Logger(subsystem: "com.maquette", category: "TileCache")

    private struct CacheEntry {
        let data: Data
    }

    /// Creates a tile cache.
    /// - Parameter maxMemoryEntries: Maximum number of tiles held in memory. Default `100`.
    public init(maxMemoryEntries: Int = 100) {
        self.maxMemoryEntries = maxMemoryEntries

        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("Maquette/Tiles", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.diskCacheURL = dir
        } else {
            self.diskCacheURL = nil
        }
    }

    /// Returns cached tile data or fetches it from the provider, caching the result.
    public func cachedOrFetch(
        x: Int, y: Int, zoom: Int,
        provider: any TileProvider
    ) async throws -> Data {
        let key = "\(provider.providerIdentifier)-\(zoom)-\(x)-\(y)"

        // Check memory cache
        if let entry = memoryCache[key] {
            touchKey(key)
            return entry.data
        }

        // Check disk cache
        if let diskData = readFromDisk(key: key) {
            storeInMemory(key: key, data: diskData)
            return diskData
        }

        // Fetch from provider
        let data = try await provider.fetchTile(x: x, y: y, zoom: zoom)

        storeInMemory(key: key, data: data)
        writeToDisk(key: key, data: data)

        return data
    }

    /// Removes all cached data from memory and disk.
    public func clearAll() {
        memoryCache.removeAll()
        accessOrder.removeAll()

        if let diskCacheURL {
            try? FileManager.default.removeItem(at: diskCacheURL)
            try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        }
    }

    // MARK: - Private

    private func touchKey(_ key: String) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    private func storeInMemory(key: String, data: Data) {
        memoryCache[key] = CacheEntry(data: data)
        touchKey(key)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while memoryCache.count > maxMemoryEntries, let oldest = accessOrder.first {
            memoryCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func readFromDisk(key: String) -> Data? {
        guard let url = diskFileURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeToDisk(key: String, data: Data) {
        guard let url = diskFileURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func diskFileURL(for key: String) -> URL? {
        guard let diskCacheURL else { return nil }
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return diskCacheURL.appendingPathComponent(safeKey)
    }
}
