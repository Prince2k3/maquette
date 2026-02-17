import Foundation

/// Protocol for sources that serve OGC 3D Tiles tilesets.
///
/// Conforming types handle authentication and tile fetching for services like
/// Google Photorealistic 3D Tiles and Cesium ion.
public protocol Tiles3DProvider: Sendable {
    /// Fetches the root tileset.json.
    func fetchTileset() async throws -> TilesetJSON

    /// Fetches a child tile's content (GLB binary).
    /// - Parameter uri: The relative or absolute URI from the tile's content property.
    func fetchTileContent(uri: String) async throws -> Data

    /// Attribution text required by the provider (e.g., "Google", "Cesium").
    var attribution: String { get }
}
