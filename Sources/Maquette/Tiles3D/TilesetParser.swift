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
///
/// Supports both `uri` (3D Tiles 1.1) and `url` (3D Tiles 1.0) keys.
public struct TileContentJSON: Codable, Sendable {
    /// URI to the tile's content (relative or absolute).
    public let uri: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 3D Tiles 1.1 uses "uri", 1.0 uses "url"
        if let uri = try container.decodeIfPresent(String.self, forKey: .uri) {
            self.uri = uri
        } else if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            self.uri = url
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.uri,
                .init(codingPath: decoder.codingPath, debugDescription: "Neither 'uri' nor 'url' found in tile content")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case url
    }
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
