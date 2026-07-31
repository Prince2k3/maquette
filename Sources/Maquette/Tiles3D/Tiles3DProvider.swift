import Foundation

/// Protocol for sources that serve OGC 3D Tiles tilesets.
///
/// Conforming types handle authentication and tile fetching for services like
/// Google Photorealistic 3D Tiles and Cesium ion.
public protocol Tiles3DProvider: Sendable {
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
