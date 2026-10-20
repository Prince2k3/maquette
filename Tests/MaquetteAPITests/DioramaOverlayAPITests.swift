import CoreGraphics
import Maquette
import SwiftUI
import Testing

@Suite("Geographic overlay public API")
@MainActor
struct DioramaOverlayAPITests {
    @Test func geographicContentStylesAndSelectionCompile() throws {
        let p = Coordinate(latitude: 36, longitude: -112)
        let polygon = Polygon(exterior: LinearRing([p, .init(latitude: 36.01, longitude: -112), .init(latitude: 36, longitude: -111.99)]))
        let pixels = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let resource = DioramaImageResource(id: "survey", revision: "1", image: pixels, attribution: "Survey team")
        _ = DioramaView(initialRegion: .init(center: p, radius: 6000), selection: Binding<UUID?>.constant(nil)) {
            DioramaPolygon(polygon, id: "park").fill(.green.opacity(0.2))
                .stroke(.green, width: .physicalMeters(0.002)).tag(UUID())
            DioramaCircle(center: p, radius: 500, id: "circle").tag(UUID())
                .stroke(.blue, style: .init(width: .geographicMeters(10), lineCap: .round, lineJoin: .round,
                                            dash: [20, 10], dashPhase: 5)).fill(.blue.opacity(0.1))
            DioramaImageOverlay(image: resource, bounds: .init(west: -112, south: 36, east: -111.99, north: 36.01))
                .opacity(0.6)
            DioramaFeature(Feature(geometry: .polygon(polygon))).fill(.mint).stroke(.green, width: .physicalMeters(0.002))
            DioramaPolyline(coordinates: [p, .init(latitude: 36.01, longitude: -112)])
                .stroke(.orange, style: .init(width: .geographicMeters(5), lineCap: .square, lineJoin: .bevel))
        }
    }
}
