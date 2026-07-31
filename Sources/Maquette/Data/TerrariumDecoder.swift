import CoreGraphics
import Foundation
import ImageIO

/// Decodes Terrarium-encoded elevation tiles, whatever image format they arrive in.
///
/// Both terrain providers ship the same encoding — `elevation = (red * 256 + green + blue / 256)
/// − 32768` — and differ only in container: Mapzen serves PNG, MapTiler serves WebP. ImageIO
/// decodes both (and JPEG besides), so one decoder serves every provider and the call sites stop
/// branching on provider identity to choose between two functions that produced identical output.
enum TerrariumDecoder {
    /// Decodes Terrarium-encoded image data (PNG, WebP, or JPEG) into an elevation grid.
    static func decodeElevation(from imageData: Data) throws -> ElevationGrid {
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
