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
public struct MapTilerSatelliteProvider: TileProvider, Sendable {
    public let providerIdentifier = "maptiler-satellite"

    private let apiKey: String
    private let httpClient: any HTTPClient
    private let logger = Logger(subsystem: "com.maquette", category: "MapTilerSatelliteProvider")

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

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw DioramaError.authenticationFailed(provider: "MapTiler")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "MapTiler", retryAfter: retryAfter)
        default:
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }
    }
}
