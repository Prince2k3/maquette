import Foundation
import CryptoKit

/// The identity and revision of a 3D Tiles source, used to decide when a view reloads.
///
/// Construct the same identity for interchangeable sources, and change the source or revision
/// whenever fetching could return a different dataset. Values are stored as an opaque digest;
/// neither the source string nor the revision is retained.
public struct Tiles3DSourceID: Hashable, Sendable {
    private let digest: Data

    /// Creates an identity from an application-defined source name and content revision.
    public init(_ source: String, revision: String = "") {
        self.init(components: ["custom", source, revision])
    }

    init(components: [String]) {
        var hasher = SHA256()
        for component in components {
            let bytes = Data(component.utf8)
            // Length framing prevents different component boundaries from sharing an identity.
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        digest = Data(hasher.finalize())
    }
}

/// Protocol for sources that serve OGC 3D Tiles tilesets.
///
/// Conforming types handle authentication and tile fetching for services like
/// Google Photorealistic 3D Tiles and Cesium ion.
public protocol Tiles3DProvider: Sendable {
    /// Stable source and revision identity for reload comparison.
    ///
    /// Include every setting that changes the fetched dataset, including asset, endpoint,
    /// revision, and authorization context. Keep this value stable for the provider's lifetime;
    /// supply a new provider and identity when its source changes. Attribution is display text
    /// and is never used as source identity.
    ///
    /// The default is `nil` for compatibility. Without an identity, each construction of
    /// `DioramaStyle.photorealistic` conservatively represents a new source. Retain that style
    /// between view updates, or implement this property to avoid unnecessary reloads.
    var sourceID: Tiles3DSourceID? { get }

    /// Fetches the raw bytes of the root tileset.json. The library parses it.
    ///
    /// Returning `Data` rather than a parsed document is deliberate: it keeps the 3D Tiles wire
    /// format out of the public API, and a custom provider already has bytes in hand — parsing was
    /// work the protocol forced on it only to be undone.
    func fetchTileset() async throws -> Data

    /// Fetches a child tile's content (GLB binary, or a nested tileset.json).
    /// - Parameter uri: The relative or absolute URI from the tile's content property.
    func fetchTileContent(uri: String) async throws -> Data

    /// Attribution text required by the provider (e.g., "Google", "Cesium").
    var attribution: String { get }
}

extension Tiles3DProvider {
    public var sourceID: Tiles3DSourceID? { nil }
}

/// Keeps a legacy provider's fallback identity through style/configuration round trips.
struct IdentifiedTiles3DProvider: Tiles3DProvider {
    let provider: any Tiles3DProvider
    let sourceID: Tiles3DSourceID? = Tiles3DSourceID(components: ["legacy", UUID().uuidString])

    var attribution: String { provider.attribution }

    func fetchTileset() async throws -> Data {
        try await provider.fetchTileset()
    }

    func fetchTileContent(uri: String) async throws -> Data {
        try await provider.fetchTileContent(uri: uri)
    }
}
