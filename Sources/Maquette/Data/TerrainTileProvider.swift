import CoreGraphics
import Foundation
import os

/// A 2D grid of elevation values in meters.
public struct ElevationGrid: Sendable {
    /// Width of the grid (number of columns).
    public let width: Int
    /// Height of the grid (number of rows).
    public let height: Int
    /// Elevation values in row-major order (meters above sea level).
    public let values: [Float]

    /// The lowest elevation in the grid.
    ///
    /// Measured once, in ``init(width:height:values:)``, rather than scanned on each read. The
    /// values never change, so the two are the same answer — but a tile is a quarter of a million
    /// floats and `TerrainHeightField` asks every resident grid for its extremes every time one is
    /// constructed, which is twice per ground-zoom step. Measured on a chunk sitting over 40 tiles,
    /// that scan was **4.1 ms of a 10.5 ms zoom step**, and it grew with the window rather than
    /// with the work: at 9 tiles the same step spent 1.2 ms there.
    public let minElevation: Float

    /// The highest elevation in the grid. See ``minElevation``.
    public let maxElevation: Float

    /// Creates an elevation grid.
    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values

        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for value in values {
            low = min(low, value)
            high = max(high, value)
        }
        self.minElevation = values.isEmpty ? 0 : low
        self.maxElevation = values.isEmpty ? 0 : high
    }

    /// Returns the elevation value at the given column and row.
    public func elevation(atColumn col: Int, row: Int) -> Float {
        values[row * width + col]
    }
}

/// Fetches and decodes Mapzen Terrarium-encoded elevation tiles from AWS.
public struct TerrainTileProvider: TileProvider, Sendable {
    public let providerIdentifier = "terrarium"

    private static let baseURL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"
    private let httpClient: any HTTPClient
    private let logger = Logger(maquette: "TerrainTileProvider")

    /// Creates a terrain tile provider.
    /// - Parameter httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(httpClient: any HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    public func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        let urlString = "\(Self.baseURL)/\(zoom)/\(x)/\(y).png"
        guard let url = URL(string: urlString) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        logger.debug("Fetching terrain tile: \(urlString)")

        let request = MaquetteHTTP.request(for: url)
        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        return data
    }

    /// Decodes Terrarium-encoded PNG data into an elevation grid.
    ///
    /// Terrarium encoding: `elevation = (red * 256 + green + blue / 256) - 32768`
    public static func decodeElevation(from pngData: Data) throws -> ElevationGrid {
        try TerrariumDecoder.decodeElevation(from: pngData)
    }
}
