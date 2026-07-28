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
    /// The visual treatment laid over the built chunk. An effect is a restyle rather than a
    /// different configuration, which is why it sits beside one rather than inside it.
    var effect: DioramaEffect = .none
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
            // Photogrammetry cut to the outline, resting on a tray. Straight to Google rather
            // than proxied through Cesium ion. Google bills only the root tileset request, and the
            // provider caches that, so relaunching the demo does not keep costing events.
            //
            // The radius is what makes or breaks this path. Level of detail is chosen from the
            // model's on-screen size, so a wide region is a small region: ten kilometres of city
            // squeezed into a chunk the size of a dinner plate leaves a building two pixels tall,
            // and the tileset correctly refuses to refine past flat draped imagery. Roughly a
            // kilometre is where facades start reading as facades.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.7929, longitude: -122.3971),
                radiusMeters: 700,
                presentation: .photorealistic(
                    provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                    style: .detailed
                )
            )
            camera(&configuration)
            return DemoPreset(
                id: "photoreal",
                title: "City",
                caption: "San Francisco downtown, cut to the outline",
                configuration: configuration
            )
        }(),

        {
            // Half Dome, the end of the trail out of Yosemite Valley. Natural terrain rather than
            // buildings, and 1,400 m of relief inside the outline — the case where a flat-looking
            // model is unmistakably wrong.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332),
                radiusMeters: 1400,
                presentation: .photorealistic(
                    provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                    style: .detailed
                )
            )
            camera(&configuration)
            configuration.cameraElevation = 0.28
            // 1,400 m of relief on an 0.8 m footprint makes this the tallest preset by some way,
            // so the shared framing crops it. Pull back until the summit and the valley floor are
            // in frame together — that contrast is the whole point of the preset.
            configuration.cameraDistance = 1.7
            return DemoPreset(
                id: "photoreal-trail",
                title: "Trail",
                caption: "Half Dome, Yosemite — photoreal terrain",
                configuration: configuration
            )
        }(),

        {
            // Fetches a region 80% wider than the chunk, so the first drag is served without a
            // fetch. Dragging past that rolls new tiles in rather than stopping, so the Grand
            // Canyon is only where this one starts.
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

        {
            // The same gesture over streamed photogrammetry. `panRange` widens what the tile
            // traversal keeps rather than what is fetched up front — the ground outside the outline
            // is streamed and cut away, and sliding the outline onto it is what brings it back.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.7929, longitude: -122.3971),
                radiusMeters: 700,
                panRange: 0.6,
                presentation: .photorealistic(
                    provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                    style: .detailed
                )
            )
            camera(&configuration)
            return DemoPreset(
                id: "photoreal-pan",
                title: "Pan 3D",
                caption: "Slide the outline across San Francisco",
                configuration: configuration
            )
        }(),

        {
            // Deliberately the same ground as the Pan preset, and pannable, because the effect has
            // to survive a pan: contours are re-traced from the chunk's re-sampled triangles on
            // every step, and a roll hands the chunk a fresh surface material underneath them.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radiusMeters: 6000,
                elevationExaggeration: 1.6,
                chunk: .canyon,
                panRange: 0.8
            )
            camera(&configuration)
            return DemoPreset(
                id: "hologram",
                title: "Hologram",
                caption: "Projected contours over the Grand Canyon",
                configuration: configuration,
                effect: .hologram
            )
        }(),

        {
            // The reason this preset is a small radius over a dense downtown: OSM footprints are
            // the only thing standing on the chunk here, since both elevation providers are
            // bare-earth and a heightfield could not hold a vertical wall anyway. Anywhere without
            // tall buildings, the layer is invisible and the preset proves nothing.
            //
            // Buildings are exaggerated past the terrain's own scale for the same reason terrain is
            // exaggerated past reality: at 800 m to the chunk's 0.8 m, a fifteen-metre block is
            // 7 mm tall and reads as texture. The towers carry the effect; the blocks around them
            // are what make it a city.
            var configuration = DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.7929, longitude: -122.3971),
                radiusMeters: 800,
                elevationExaggeration: 1.6,
                chunk: .canyon,
                panRange: 0.8,
                buildings: BuildingStyle(exaggeration: 1.5)
            )
            camera(&configuration)
            return DemoPreset(
                id: "buildings",
                title: "City grid",
                caption: "OSM buildings extruded over San Francisco",
                configuration: configuration,
                effect: .hologram
            )
        }(),

    ]
}

struct ContentView: View {
    @State private var selection = DemoPresets.all.firstIndex {
        $0.id == ProcessInfo.processInfo.environment["MAQUETTE_PRESET"]
    } ?? 0

    @State private var buildingsVisible = true

    private var preset: DemoPreset { DemoPresets.all[selection] }

    /// The preset's configuration with the live toggles folded in.
    ///
    /// Flipping `isVisible` hands `DioramaView` a changed configuration on a view whose `id` has not
    /// moved, so the store is the one already loaded and the buildings are hidden rather than refetched.
    private var configuration: DioramaConfiguration {
        var configuration = preset.configuration
        configuration.buildings?.isVisible = buildingsVisible
        return configuration
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                DioramaView(configuration: configuration)
                    .dioramaEffect(preset.effect)
                    .id(preset.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if preset.configuration.buildings != nil {
                    buildingsToggle
                }
                presetPicker
            }
        }
        .preferredColorScheme(.dark)
    }

    private var buildingsToggle: some View {
        Toggle("Buildings", isOn: $buildingsVisible)
            .font(.subheadline.weight(.medium))
            .toggleStyle(.switch)
            .tint(.accentColor)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("toggle-buildings")
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
