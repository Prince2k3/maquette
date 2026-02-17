import Foundation

/// Parsed representation of an OGC 3D Tiles tileset.json.
public struct TilesetJSON: Codable, Sendable {
    /// Asset metadata (version, etc.).
    public let asset: TilesetAsset
    /// The root geometric error of the tileset.
    public let geometricError: Double
    /// The root tile of the tileset tree.
    public let root: TileJSON

    /// Asset metadata within a tileset.
    public struct TilesetAsset: Codable, Sendable {
        /// 3D Tiles specification version (e.g., "1.1").
        public let version: String
        /// Optional tileset-specific version string.
        public let tilesetVersion: String?
    }
}

/// A single tile in the 3D Tiles hierarchy.
public struct TileJSON: Codable, Sendable {
    /// The bounding volume of this tile.
    public let boundingVolume: BoundingVolumeJSON
    /// Geometric error for this tile, used in LOD decisions.
    public let geometricError: Double
    /// Refinement strategy: ADD or REPLACE.
    public let refine: RefinementStrategy?
    /// Content (GLB URI) for this tile, if any.
    public let content: TileContentJSON?
    /// Child tiles.
    public let children: [TileJSON]?
    /// 4x4 column-major transform matrix (16 doubles).
    public let transform: [Double]?
}

/// Tile content reference (URI to GLB or other tile data).
public struct TileContentJSON: Codable, Sendable {
    /// URI to the tile's content (relative or absolute).
    public let uri: String
}

/// Bounding volume representation from tileset.json.
public struct BoundingVolumeJSON: Codable, Sendable {
    /// Region bounding volume: [west, south, east, north, minHeight, maxHeight] in radians.
    public let region: [Double]?
    /// Oriented bounding box: 12 floats — center(3) + x-half-axis(3) + y-half-axis(3) + z-half-axis(3).
    public let box: [Double]?
    /// Bounding sphere: 4 floats — center(3) + radius.
    public let sphere: [Double]?
}

/// Refinement strategy for tile tree traversal.
public enum RefinementStrategy: String, Codable, Sendable {
    /// Render children in addition to the parent.
    case add = "ADD"
    /// Render children instead of the parent.
    case replace = "REPLACE"
}
