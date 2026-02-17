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
public struct MapTilerTerrainProvider: TileProvider, Sendable {
    public let providerIdentifier = "maptiler-terrain"

    private let apiKey: String
    private let httpClient: any HTTPClient
    private let logger = Logger(subsystem: "com.maquette", category: "MapTilerTerrainProvider")

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

    /// Decodes Terrarium-encoded image data (PNG, WebP, or JPEG) into an elevation grid.
    ///
    /// Uses ImageIO for format-agnostic decoding, then applies the Terrarium formula:
    /// `elevation = (red * 256 + green + blue / 256) - 32768`
    public static func decodeElevation(from imageData: Data) throws -> ElevationGrid {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
