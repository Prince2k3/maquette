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
    private let session: URLSession
    private let logger = Logger(subsystem: "com.maquette", category: "TerrainTileProvider")

    /// Creates a terrain tile provider.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        let urlString = "\(Self.baseURL)/\(zoom)/\(x)/\(y).png"
        guard let url = URL(string: urlString) else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }

        logger.debug("Fetching terrain tile: \(urlString)")

        let (data, response) = try await session.data(from: url)

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
        guard let cgDataProvider = CGDataProvider(data: pngData as CFData),
              let cgImage = CGImage(
                  pngDataProviderSource: cgDataProvider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw DioramaError.elevationDecodingFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DioramaError.elevationDecodingFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var elevations = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let offset = i * bytesPerPixel
            let r = Float(pixelData[offset])
            let g = Float(pixelData[offset + 1])
            let b = Float(pixelData[offset + 2])
            elevations[i] = (r * 256.0 + g + b / 256.0) - 32768.0
        }

        return ElevationGrid(width: width, height: height, values: elevations)
    }
}
