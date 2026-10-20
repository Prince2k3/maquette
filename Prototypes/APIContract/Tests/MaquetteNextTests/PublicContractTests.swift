import CoreGraphics
import MaquetteNext
import SwiftUI
import Testing

@Suite("Next API public-import contracts")
@MainActor
struct PublicContractTests {
    private let point = Coordinate(latitude: 36, longitude: -112)
    private enum Selection: Hashable, Sendable { case summit, park }

    private struct RouteContent: DioramaContent {
        let path: [Coordinate]
        var body: some DioramaContent {
            DioramaPolyline(coordinates: path)
                .stroke(.orange, style: DioramaStrokeStyle(width: .geographicMeters(8), lineCap: .round))
            if let start = path.first {
                DioramaMarker("Start", coordinate: start).tag(Selection.summit)
            }
        }
    }

    @Test func allContentPrimitivesAndDataCompose() {
        let polygon = Polygon([point, Coordinate(latitude: 36.01, longitude: -112),
                               Coordinate(latitude: 36, longitude: -111.99)])
        let bounds = GeographicBounds(enclosing: polygon.exterior!.coordinates)!
        let pixels = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let image = DioramaImageResource(id: "survey", revision: "1", image: pixels)
        let group = DioramaContentGroup {
            DioramaMarker("Summit", coordinate: point).tint(.orange).tag(Selection.summit)
            DioramaAnnotation("Start", coordinate: point, anchor: .bottom) {
                Label("Start here", systemImage: "figure.hiking")
            }.id("label").tag(Selection.summit)
            RouteContent(path: [point, point])
            DioramaPolygon(polygon).fill(.green.opacity(0.2))
                .stroke(.green, width: .physicalMeters(0.002)).tag(Selection.park)
            DioramaCircle(center: point, radius: 500).fill(.blue).opacity(0.3)
            DioramaImageOverlay(image: image, bounds: bounds).opacity(0.6)
            DioramaFeature(Feature.point(point), style: .init(pointTint: .orange, fill: .green))
            Feature.point(point)
            FeatureCollection([Feature.point(point)])
            ForEach([1, 2], id: \.self) { id in
                DioramaMarker("Place \(id)", coordinate: point)
            }
        }
        _ = group
    }

    @Test func independentNavigationHostsAndCameraActionsCompile() {
        let region = DioramaRegion(center: point, radius: 6000)
        let ground: Binding<DioramaGroundPosition> = .constant(.init(region: region))
        let camera: Binding<DioramaCameraPosition> = .constant(.camera(.init(
            heading: .degrees(45), pitch: .degrees(60), distance: 1.2,
            focus: .coordinate(point, altitude: .clampToGround)
        )))
        _ = HStack {
            DioramaReader { proxy in
                DioramaView(groundPosition: ground, cameraPosition: camera,
                            selection: Binding<Selection?>.constant(nil)) {
                    RouteContent(path: [point, point])
                }
                Button("Fit") { _ = proxy.fit(.chunk, padding: .init(top: 20, leading: 20, bottom: 20, trailing: 20)) }
                Button("Repeat fit") { _ = proxy.fit(.contentIDs(["label"])) }
                Button("Cancel") { proxy.cancel() }
            }
            DioramaReader { _ in
                DioramaView(initialRegion: region, selection: Binding<UUID?>.constant(nil)) {
                    DioramaMarker(coordinate: point).tag(UUID())
                }
            }
        }
        _ = DioramaView(initialRegion: region)
        _ = DioramaView(initialRegion: region, initialCamera: .camera(.init(pitch: .degrees(0))),
                        interactionModes: [.heading, .groundZoom])
        _ = DioramaView(initialRegion: region, cameraPosition: camera)
        _ = DioramaView(initialRegion: region, cameraPosition: camera, selection: Binding<Selection?>.constant(nil))
        _ = DioramaView(groundPosition: ground, selection: Binding<Selection?>.constant(nil))
        _ = DioramaView(groundPosition: ground, cameraPosition: camera)
        _ = DioramaCameraLimits(distance: 0.3...3, pitchDegrees: 0...80)
        _ = DioramaCameraTransition.easeInOut(duration: 0.35)
    }
}
