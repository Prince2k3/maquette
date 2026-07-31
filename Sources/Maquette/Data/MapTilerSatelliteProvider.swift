import Foundation
import os

/// Fetches high-resolution satellite imagery tiles from MapTiler.
///
/// Requires a MapTiler API key, available for free at https://www.maptiler.com/cloud/
///
/// Usage:
/// ```swift
/// let provider = MapTilerSatelliteProvider(apiKey: "your-key")
/// let tileData = try await provider.fetchTile(x: 536, y: 358, zoom: 10)
/// ```
struct MapTilerSatelliteProvider: TileProvider, Sendable {
    public let providerIdentifier = "maptiler-satellite"

    private let apiKey: String
    private let httpClient: any HTTPClient
    private let logger = Logger(maquette: "MapTilerSatelliteProvider")

    /// Creates a MapTiler satellite tile provider.
    /// - Parameters:
    ///   - apiKey: MapTiler API key.
    ///   - httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(apiKey: String, httpClient: any HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    public func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        let urlString = "https://api.maptiler.com/tiles/satellite-v2/\(zoom)/\(x)/\(y).jpg?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        logger.debug("Fetching MapTiler satellite tile: z=\(zoom) x=\(x) y=\(y)")

        let request = MaquetteHTTP.request(for: url)
        let (data, response) = try await httpClient.data(for: request)
        return try MaquetteHTTP.validateTileResponse(
            response, data: data, provider: "MapTiler", x: x, y: y, zoom: zoom
        )
    }
}
