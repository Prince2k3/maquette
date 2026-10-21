import CoreGraphics
import Maquette

/// Stable resources keep SwiftUI body evaluation out of the workload's input generation.
enum PerformanceWorkload: String, CaseIterable, Identifiable {
    case labels = "100 labels"
    case path = "10,000-point path"
    case polygons = "10,000 polygon vertices"
    case images = "Four 2048px images"

    var id: Self { self }

    static func coordinate(x: Double, z: Double) -> Coordinate {
        Turf.destination(from: Coordinate(latitude: 36.0544, longitude: -112.1401),
                         meters: hypot(x, z), bearing: atan2(x, -z) * 180 / .pi)
    }

    static let pathCoordinates = (0..<10_000).map { index in
        let x = Double(index) / 9_999 * 1_400 - 700
        return coordinate(x: x, z: sin(x / 120) * 250)
    }

    static let polygonData: [Maquette.Polygon] = (0..<25).map { index in
        func ring(radius: Double, count: Int) -> LinearRing {
            LinearRing((0..<count).map { vertex in
                let angle = Double(vertex) / Double(count) * .pi * 2
                return coordinate(x: Double(index % 5) * 280 - 560 + cos(angle) * radius,
                                  z: Double(index / 5) * 280 - 560 + sin(angle) * radius)
            })
        }
        return Maquette.Polygon(exterior: ring(radius: 100, count: 300), holes: [ring(radius: 40, count: 100)])
    }

    static let bounds = GeographicBounds(enclosing: [coordinate(x: -700, z: -700), coordinate(x: 700, z: 700)])!

    // Construction failure is explicit: a capture must never silently use fewer/smaller images.
    static let imageResources: [DioramaImageResource] = (0..<4).map { index in
        guard let context = CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
            bytesPerRow: 8192, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            preconditionFailure("Cannot allocate performance image")
        }
        context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
        guard let image = context.makeImage() else { preconditionFailure("Cannot create performance image") }
        return DioramaImageResource(id: "perf-image-\(index)", revision: "1", image: image)
    }
}
