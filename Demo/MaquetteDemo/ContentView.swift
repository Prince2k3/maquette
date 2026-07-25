import CoreLocation
import Maquette
import SwiftUI

/// A named chunk configuration, chosen to exercise a specific part of the reframe.
struct DemoPreset: Identifiable {
    let id: String
    let title: String
    /// What this preset is meant to demonstrate.
    let caption: String
    let configuration: DioramaConfiguration
}

enum DemoPresets {
    /// Camera framing shared by every preset so the presets differ only in what they demonstrate.
    private static func camera(_ configuration: inout DioramaConfiguration) {
        configuration.cameraElevation = 0.45
        configuration.cameraDistance = 1.3
    }

    static let all: [DemoPreset] = [
        {
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radiusMeters: 6000,
                elevationExaggeration: 1.6,
                chunk: .canyon
            )
            camera(&configuration)
            return DemoPreset(
                id: "canyon",
                title: "Canyon",
                caption: "Circular chunk, canyon strata walls",
                configuration: configuration
            )
        }(),

        {
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 46.8523, longitude: -121.7603),
                radiusMeters: 9000,
                shape: .hexagonal,
                elevationExaggeration: 1.6,
                chunk: .alpine
            )
            camera(&configuration)
            return DemoPreset(
                id: "hexagon",
                title: "Hexagon",
                caption: "Hexagonal outline, alpine strata",
                configuration: configuration
            )
        }(),

        {
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.7460, longitude: -119.5332),
                radiusMeters: 5000,
                shape: .roundedRectangular(width: 0.9, depth: 0.65, cornerRadius: 0.12),
                physicalDiameter: 0.9,
                elevationExaggeration: 1.6,
                chunk: TerrainChunkStyle(
                    baseDepth: .proportional(0.2),
                    wall: .strata(.earth),
                    base: .plinth(color: Color(white: 0.1), height: 0.03, inset: -0.025)
                )
            )
            camera(&configuration)
            // Wider than the other presets, so pull back to keep it in frame.
            configuration.cameraDistance = 1.7
            return DemoPreset(
                id: "plinth",
                title: "Plinth",
                caption: "Rounded rectangle on a plinth",
                configuration: configuration
            )
        }(),

        {
            // A five-pointed star, to prove arbitrary outlines clip correctly.
            let points: [SIMD2<Float>] = (0..<10).map { index in
                let radius: Float = index.isMultiple(of: 2) ? 0.45 : 0.19
                let angle = Float(index) / 10 * 2 * .pi - .pi / 2
                return SIMD2(radius * cos(angle), radius * sin(angle))
            }
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.2692, longitude: -112.9466),
                radiusMeters: 4000,
                shape: .custom(points: points),
                elevationExaggeration: 1.6,
                chunk: TerrainChunkStyle(
                    baseDepth: .proportional(0.16),
                    wall: .strata(.canyon)
                )
            )
            camera(&configuration)
            return DemoPreset(
                id: "star",
                title: "Star",
                caption: "Arbitrary concave outline",
                configuration: configuration
            )
        }(),

        {
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radiusMeters: 6000,
                elevationExaggeration: 1.6,
                chunk: .surfaceOnly
            )
            camera(&configuration)
            return DemoPreset(
                id: "surface",
                title: "Surface",
                caption: "No earth beneath — surface only",
                configuration: configuration
            )
        }(),

        {
            // Photogrammetry cut to the outline, resting on a tray. Uses the Cesium ion token
            // already committed in DioramaPreview.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.773972, longitude: -122.431297),
                radiusMeters: 5000,
                presentation: .photorealistic(
                    provider: CesiumIonTiles3DProvider(
                        accessToken: "***REMOVED-CESIUM-ION-TOKEN***",
                        assetId: 2275207
                    ),
                    style: .standard
                )
            )
            camera(&configuration)
            return DemoPreset(
                id: "photoreal",
                title: "Photo",
                caption: "3D Tiles cut to the outline, on a tray",
                configuration: configuration
            )
        }(),

        {
            // Fetches a region 80% wider than the chunk, so the terrain has room to slide.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radiusMeters: 5000,
                elevationExaggeration: 1.6,
                chunk: .canyon,
                panRange: 0.8
            )
            camera(&configuration)
            return DemoPreset(
                id: "pan",
                title: "Pan",
                caption: "One finger slides terrain, two orbit",
                configuration: configuration
            )
        }(),
    ]
}

struct ContentView: View {
    @State private var selection = 0

    private var preset: DemoPreset { DemoPresets.all[selection] }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                DioramaView(configuration: preset.configuration)
                    .id(preset.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                presetPicker
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(preset.title)
                .font(.title2.weight(.semibold))
            Text(preset.caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(DemoPresets.all.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selection = index
                    } label: {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(index == selection ? Color.accentColor : Color(white: 0.18))
                            )
                            .foregroundStyle(index == selection ? Color.white : Color.secondary)
                    }
                    .accessibilityIdentifier("preset-\(item.id)")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }
}
