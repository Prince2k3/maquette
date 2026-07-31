import Foundation

/// Interface for fetching map tile data.
///
/// Conforming types provide tile image data for a given slippy-map coordinate.
/// The library ships with ``TerrainTileProvider`` and ``SatelliteTileProvider``;
/// developers can supply custom implementations via this protocol.
protocol TileProvider: Sendable {
    /// A stable identifier for this provider, used as part of the cache key.
    var providerIdentifier: String { get }

    /// Fetches the raw tile data (typically a PNG or JPEG image) for the given tile coordinates.
    /// - Parameters:
    ///   - x: Tile column.
    ///   - y: Tile row.
    ///   - zoom: Zoom level.
    /// - Returns: The raw image data for the tile.
    func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data
}
