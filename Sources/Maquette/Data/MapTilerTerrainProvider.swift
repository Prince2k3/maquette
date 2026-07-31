import CoreGraphics
import Foundation
import ImageIO
import os

/// Fetches terrain elevation tiles from MapTiler.
///
/// Uses Terrarium-encoded tiles from MapTiler's terrain endpoint.
/// Higher resolution than the default Mapzen provider in many regions.
///
/// Requires a MapTiler API key, available for free at https://www.maptiler.com/cloud/
struct MapTilerTerrainProvider: TileProvider, Sendable {
    public let providerIdentifier = "maptiler-terrain"

    private let apiKey: String
    private let httpClient: any HTTPClient
    private let logger = Logger(maquette: "MapTilerTerrainProvider")

    /// Creates a MapTiler terrain tile provider.
    /// - Parameters:
    ///   - apiKey: MapTiler API key.
    ///   - httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(apiKey: String, httpClient: any HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    public func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        let urlString = "https://api.maptiler.com/tiles/terrain-rgb-v2/\(zoom)/\(x)/\(y).webp?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        logger.debug("Fetching MapTiler terrain tile: z=\(zoom) x=\(x) y=\(y)")

        let request = MaquetteHTTP.request(for: url)
        let (data, response) = try await httpClient.data(for: request)
        return try MaquetteHTTP.validateTileResponse(
            response, data: data, provider: "MapTiler", x: x, y: y, zoom: zoom
        )
    }

    /// Decodes Terrarium-encoded image data (PNG, WebP, or JPEG) into an elevation grid.
    ///
    /// Uses ImageIO for format-agnostic decoding, then applies the Terrarium formula:
    /// `elevation = (red * 256 + green + blue / 256) - 32768`
    public static func decodeElevation(from imageData: Data) throws -> ElevationGrid {
        try TerrariumDecoder.decodeElevation(from: imageData)
    }
}
