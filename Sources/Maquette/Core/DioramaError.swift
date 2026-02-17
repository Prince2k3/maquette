import Foundation

/// Errors that can occur during diorama construction and rendering.
public enum DioramaError: Error, Sendable {
    /// A network request failed.
    case networkFailure(underlying: any Error)
    /// The requested tile was not found.
    case tileNotFound(x: Int, y: Int, zoom: Int)
    /// Elevation data could not be decoded from the terrain tile.
    case elevationDecodingFailed
    /// Mesh generation failed.
    case meshGenerationFailed(reason: String)
    /// The provided configuration is invalid.
    case invalidConfiguration(reason: String)
    /// Authentication failed (401/403) — bad or missing API key.
    case authenticationFailed(provider: String)
    /// Rate limited (429) — too many requests.
    case rateLimited(provider: String, retryAfter: Int?)
    /// A provider session token has expired and needs to be refreshed.
    case sessionExpired
    /// GLB/glTF binary parsing failed.
    case glbParsingFailed(reason: String)
    /// The tile uses an unsupported format (e.g., Draco mesh compression).
    case unsupportedTileFormat(reason: String)
    /// Failed to parse a 3D Tiles tileset.json.
    case tilesetParsingFailed(reason: String)
    /// ECEF coordinate conversion failed.
    case coordinateConversionFailed
}
