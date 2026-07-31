import Foundation
import os

/// Caches root tileset responses across loads and app launches.
///
/// For Google's Photorealistic 3D Tiles the **root tileset request is the billable event** —
/// Google's documentation states that session token requests and individual tile requests do not
/// count against quota. So the cost of a diorama is not how much geometry it streams but how often
/// it asks for the root, and without this every load, every preset switch, and every relaunch is
/// another charge.
///
/// The cached response carries the session token embedded in its tile URIs, so reusing it reuses
/// the session too. That is why entries expire: a stale session makes every tile URI fail, and
/// re-requesting the root is the only way to recover.
public actor RootTilesetCache {
    /// Shared cache, so separate stores and views reuse one root request.
    public static let shared = RootTilesetCache()

    private struct Entry {
        let data: Data
        let stored: Date
    }

    private var memory: [String: Entry] = [:]
    private let directory: URL?
    private let logger = Logger(subsystem: "com.maquette", category: "RootTilesetCache")

    /// Creates a cache.
    ///
    /// - Parameter directory: Where to persist entries. Defaults to a folder in the user's cache
    ///   directory. Pass an isolated location to avoid sharing state — tests in particular, since
    ///   a shared cache would otherwise make them order-dependent and leak entries between runs.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            self.directory = caches?.appendingPathComponent("MaquetteRootTilesets", isDirectory: true)
        }
        if let path = self.directory {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    /// Returns a cached root tileset if one was stored recently enough to still be usable.
    ///
    /// - Parameters:
    ///   - key: Identifies the provider and credentials the root was fetched with.
    ///   - maximumAge: How long a cached root stays valid, bounded by the session's own lifetime.
    public func cached(key: String, maximumAge: TimeInterval) -> Data? {
        if let entry = memory[key] {
            guard Date().timeIntervalSince(entry.stored) < maximumAge else {
                memory.removeValue(forKey: key)
                return nil
            }
            return entry.data
        }

        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < maximumAge
        else {
            return nil
        }

        memory[key] = Entry(data: data, stored: modified)
        logger.debug("Reused cached root tileset, saving a billable request")
        return data
    }

    /// Stores a freshly fetched root tileset.
    public func store(key: String, data: Data) {
        memory[key] = Entry(data: data, stored: Date())
        guard let url = fileURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drops a cached root, forcing the next load to request a new session.
    ///
    /// Call this when tile requests start failing authentication, which is what an expired session
    /// looks like from the outside.
    public func invalidate(key: String) {
        memory.removeValue(forKey: key)
        if let url = fileURL(for: key) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent("\(Self.fileName(for: key)).json")
    }

    /// Credentials appear in cache keys, so they are hashed rather than written to disk as-is.
    static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "root-\(String(hash, radix: 36))"
    }
}
