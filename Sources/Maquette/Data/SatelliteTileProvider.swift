import Foundation
import os

/// Fetches raster satellite or map imagery tiles.
///
/// By default uses OpenStreetMap raster tiles. Developers can supply a custom URL template
/// with `{z}`, `{x}`, `{y}` placeholders.
struct SatelliteTileProvider: TileProvider, Sendable {
    public let providerIdentifier: String

    private let urlTemplate: String
    private let httpClient: any HTTPClient
    private let logger = Logger(maquette: "SatelliteTileProvider")

    /// Default satellite imagery URL template (ESRI World Imagery — free, no API key).
    public static let esriSatelliteTemplate = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"

    /// Creates a satellite tile provider.
    /// - Parameters:
    ///   - urlTemplate: URL template with `{z}`, `{x}`, `{y}` placeholders. Defaults to ESRI.
    ///   - identifier: Cache identifier. Defaults to `"satellite"`.
    ///   - httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(
        urlTemplate: String = SatelliteTileProvider.esriSatelliteTemplate,
        identifier: String = "satellite",
        httpClient: any HTTPClient = URLSession.shared
    ) {
        self.urlTemplate = urlTemplate
        self.providerIdentifier = identifier
        self.httpClient = httpClient
    }

    public func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        let urlString = urlTemplate
            .replacingOccurrences(of: "{z}", with: String(zoom))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))

        guard let url = URL(string: urlString) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        logger.debug("Fetching satellite tile: \(urlString)")

        let request = MaquetteHTTP.request(for: url)
        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        return data
    }
}
