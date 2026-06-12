import Foundation

/// Errors that can occur during diorama construction and rendering.
public enum DioramaError: LocalizedError, Sendable {
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

    public var errorDescription: String? {
        switch self {
        case .networkFailure(let underlying):
            "Network request failed: \(underlying.localizedDescription)"
        case .tileNotFound(let x, let y, let zoom):
            "Tile not found at (\(x), \(y)) zoom \(zoom)"
        case .elevationDecodingFailed:
            "Failed to decode elevation data from terrain tile"
        case .meshGenerationFailed(let reason):
            "Mesh generation failed: \(reason)"
        case .invalidConfiguration(let reason):
            "Invalid configuration: \(reason)"
        case .authenticationFailed(let provider):
            "Authentication failed for \(provider) — check your API key"
        case .rateLimited(let provider, let retryAfter):
            "Rate limited by \(provider)" + (retryAfter.map { ", retry after \($0)s" } ?? "")
        case .sessionExpired:
            "Provider session expired — try reloading"
        case .glbParsingFailed(let reason):
            "GLB parsing failed: \(reason)"
        case .unsupportedTileFormat(let reason):
            "Unsupported tile format: \(reason)"
        case .tilesetParsingFailed(let reason):
            "Tileset parsing failed: \(reason)"
        case .coordinateConversionFailed:
            "ECEF coordinate conversion failed"
        }
    }
}
