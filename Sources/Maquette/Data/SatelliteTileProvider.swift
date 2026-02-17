import Foundation
import os

/// Fetches raster satellite or map imagery tiles.
///
/// By default uses OpenStreetMap raster tiles. Developers can supply a custom URL template
/// with `{z}`, `{x}`, `{y}` placeholders.
public struct SatelliteTileProvider: TileProvider, Sendable {
    public let providerIdentifier: String

    private let urlTemplate: String
    private let session: URLSession
    private let logger = Logger(subsystem: "com.maquette", category: "SatelliteTileProvider")

    /// Default satellite imagery URL template (ESRI World Imagery — free, no API key).
    public static let esriSatelliteTemplate = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"

    /// MapTiler satellite URL template (requires API key).
    public static func mapTilerTemplate(apiKey: String) -> String {
        "https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=\(apiKey)"
    }

    /// Creates a satellite tile provider.
    /// - Parameters:
    ///   - urlTemplate: URL template with `{z}`, `{x}`, `{y}` placeholders. Defaults to OSM.
    ///   - identifier: Cache identifier. Defaults to `"satellite"`.
    ///   - session: URL session to use. Defaults to `.shared`.
    public init(
        urlTemplate: String = SatelliteTileProvider.esriSatelliteTemplate,
        identifier: String = "satellite",
        session: URLSession = .shared
    ) {
        self.urlTemplate = urlTemplate
        self.providerIdentifier = identifier
        self.session = session
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

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        return data
    }
}
