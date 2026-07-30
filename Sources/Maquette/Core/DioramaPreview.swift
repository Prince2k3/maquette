import CoreLocation
import Foundation
import SwiftUI

// MARK: - Previews

#Preview("Grand Canyon — South Kaibab Route Preview") {
    RoutePreviewDemoView()
        .frame(minWidth: 400, minHeight: 400)
}

/// Demo wrapper for route preview in SwiftUI previews.
private struct RoutePreviewDemoView: View {
    @State private var controller = RoutePreviewController()

    var body: some View {
        VStack {
            DioramaView(
                configuration: DioramaConfiguration(
                    center: CLLocationCoordinate2D(latitude: 36.0538, longitude: -112.0840),
                    radiusMeters: 3000
                )
            ) {
                DioramaAnnotation.marker(
                    at: coordinates.first ?? .init(),
                    tint: .green,
                    title: "South Kaibab Trailhead"
                )

                DioramaRoutePreview(
                    coordinates: coordinates,
                    style: RoutePreviewStyle(
                        highlightColor: .yellow,
                        dimmedColor: Color.orange.opacity(0.3)
                    )
                )
            }
            .routePreviewController(controller)

            HStack {
                Button(controller.playbackState == .playing ? "Pause" : "Play") {
                    controller.togglePlayPause()
                }
                Button("Stop") {
                    controller.stop()
                }
                Slider(value: Binding(
                    get: { Double(controller.progress) },
                    set: { controller.seek(to: Float($0)) }
                ), in: 0...1)
            }
            .padding()
        }
    }
}

#Preview("Half Dome — Yosemite") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 37.7460, longitude: -119.5332),
            radiusMeters: 4000
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Mt. Rainier — Wonderland Trail") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 46.8523, longitude: -121.7603),
            radiusMeters: 8000
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Zion — Angels Landing") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 37.2692, longitude: -112.9466),
            radiusMeters: 3000
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Torres del Paine — W Trek") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: -50.9423, longitude: -73.4068),
            radiusMeters: 10000,
            shape: .rectangular(width: 1.0, depth: 0.6),
            physicalDiameter: 1.0
        )
    )
    .frame(minWidth: 500, minHeight: 400)
}

// MARK: - Chunk Style Previews

#Preview("Chunk — Canyon strata, hexagonal") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
            radiusMeters: 5000,
            shape: .hexagonal,
            elevationExaggeration: 1.5,
            chunk: .canyon
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Chunk — Alpine slice on a plinth") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 46.8523, longitude: -121.7603),
            radiusMeters: 8000,
            shape: .roundedRectangular(width: 1.0, depth: 0.7, cornerRadius: 0.12),
            physicalDiameter: 1.0,
            elevationExaggeration: 1.5,
            chunk: TerrainChunkStyle(
                baseDepth: .proportional(0.18),
                wall: .strata(.alpine),
                base: .plinth(
                    color: Color(white: 0.12),
                    height: 0.03,
                    inset: -0.02
                )
            )
        )
    )
    .frame(minWidth: 500, minHeight: 400)
}

#Preview("Chunk — Deep block, solid walls") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 37.7460, longitude: -119.5332),
            radiusMeters: 4000,
            elevationExaggeration: 1.5,
            chunk: TerrainChunkStyle(
                baseDepth: .proportional(0.3),
                wall: .solid(Color(red: 0.30, green: 0.26, blue: 0.22))
            )
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Chunk — Surface only (no earth beneath)") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 37.2692, longitude: -112.9466),
            radiusMeters: 3000,
            elevationExaggeration: 1.5,
            chunk: .surfaceOnly
        )
    )
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Minimal — Half Dome") {
    DioramaView(
        center: CLLocationCoordinate2D(latitude: 37.7460, longitude: -119.5332),
        radius: 3000
    )
    .frame(minWidth: 400, minHeight: 400)
}

// MARK: - MapTiler Satellite Previews
// Uncomment and add your MapTiler API key to test high-resolution satellite imagery:
//
// #Preview("MapTiler Satellite — Grand Canyon") {
//     DioramaView(
//         configuration: DioramaConfiguration(
//             center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
//             radiusMeters: 5000,
//             imagerySource: .mapTilerSatellite(apiKey: "YOUR_MAPTILER_KEY")
//         )
//     )
//     .frame(minWidth: 400, minHeight: 400)
// }

// MARK: - Photorealistic 3D Tiles Previews
// Uncomment and add your Google API key to test photorealistic 3D tiles:
//
// #Preview("Google 3D Tiles — Grand Canyon") {
//     DioramaView(
//         configuration: DioramaConfiguration(
//             center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
//             radiusMeters: 5000,
//             imagerySource: .photorealistic(
//                 provider: GoogleTiles3DProvider(apiKey: "YOUR_GOOGLE_KEY")
//             )
//         )
//     )
//     .frame(minWidth: 400, minHeight: 400)
// }

/// A credential supplied to a preview through the scheme's environment rather than through source.
///
/// Previews of the photorealistic path need a provider credential, and a credential written into a
/// source file is published the moment it is committed — deleting it later does not help, because
/// the commit that added it keeps serving it. Xcode passes the active scheme's environment through
/// to previews, so `Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment Variables` is
/// enough to make these run without putting anything in the repository.
private func previewCredential(_ name: String) -> String? {
    let value = ProcessInfo.processInfo.environment[name]
    return (value?.isEmpty ?? true) ? nil : value
}

// Set MAQUETTE_CESIUM_ION_TOKEN in the scheme's environment to run this preview.
// 37.7749° N, 122.4194° W
#Preview("Cesium Ion 3D Tiles — San Francisco") {
    if let token = previewCredential("MAQUETTE_CESIUM_ION_TOKEN") {
        DioramaView(
            configuration: DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 37.773972, longitude: -122.431297),
                radiusMeters: 5000,
                presentation: .photorealistic(
                    provider: CesiumIonTiles3DProvider(
                        accessToken: token,
                        assetId: 2275207
                    ),
                    style: .standard
                )
            )
        )
        .frame(minWidth: 400, minHeight: 400)
    } else {
        Text("Set MAQUETTE_CESIUM_ION_TOKEN in the scheme's environment to run this preview.")
            .padding()
            .frame(minWidth: 400, minHeight: 400)
    }
}

let coordinates: [CLLocationCoordinate2D] = [
    .init(latitude: 36.05293, longitude: -112.08394),
    .init(latitude: 36.05297, longitude: -112.08402),
    .init(latitude: 36.05301, longitude: -112.08405),
    .init(latitude: 36.05305, longitude: -112.08408),
    .init(latitude: 36.0531, longitude: -112.08409),
    .init(latitude: 36.05314, longitude: -112.08408),
    .init(latitude: 36.05319, longitude: -112.08406),
    .init(latitude: 36.05321, longitude: -112.08401),
    .init(latitude: 36.05324, longitude: -112.08396),
    .init(latitude: 36.05325, longitude: -112.08391),
    .init(latitude: 36.05326, longitude: -112.08386),
    .init(latitude: 36.05328, longitude: -112.08381),
    .init(latitude: 36.05332, longitude: -112.08377),
    .init(latitude: 36.05336, longitude: -112.08374),
    .init(latitude: 36.05341, longitude: -112.08372),
    .init(latitude: 36.05344, longitude: -112.08368),
    .init(latitude: 36.05346, longitude: -112.08363),
    .init(latitude: 36.05347, longitude: -112.08357),
    .init(latitude: 36.05348, longitude: -112.08352),
    .init(latitude: 36.05351, longitude: -112.08347),
    .init(latitude: 36.05353, longitude: -112.08343),
    .init(latitude: 36.05356, longitude: -112.08338),
    .init(latitude: 36.0536, longitude: -112.08335),
    .init(latitude: 36.05362, longitude: -112.0833),
    .init(latitude: 36.05366, longitude: -112.08327),
    .init(latitude: 36.0537, longitude: -112.08324),
    .init(latitude: 36.05374, longitude: -112.08321),
    .init(latitude: 36.05379, longitude: -112.08319),
    .init(latitude: 36.05383, longitude: -112.0832),
    .init(latitude: 36.05384, longitude: -112.0832),
    .init(latitude: 36.05383, longitude: -112.08324),
    .init(latitude: 36.05379, longitude: -112.08327),
    .init(latitude: 36.05375, longitude: -112.08328),
    .init(latitude: 36.0537, longitude: -112.08331),
    .init(latitude: 36.05368, longitude: -112.08336),
    .init(latitude: 36.05368, longitude: -112.08342),
    .init(latitude: 36.0537, longitude: -112.08347),
    .init(latitude: 36.0537, longitude: -112.08351),
    .init(latitude: 36.05369, longitude: -112.08354),
    .init(latitude: 36.05365, longitude: -112.08355),
    .init(latitude: 36.05364, longitude: -112.08355),
    .init(latitude: 36.05361, longitude: -112.08357),
    .init(latitude: 36.05359, longitude: -112.08363),
    .init(latitude: 36.05359, longitude: -112.08368),
    .init(latitude: 36.05358, longitude: -112.08374),
    .init(latitude: 36.05358, longitude: -112.0838),
    .init(latitude: 36.0536, longitude: -112.08385),
    .init(latitude: 36.05363, longitude: -112.08389),
    .init(latitude: 36.05366, longitude: -112.08393),
    .init(latitude: 36.05367, longitude: -112.08399),
    .init(latitude: 36.05369, longitude: -112.08404),
    .init(latitude: 36.05372, longitude: -112.08408),
    .init(latitude: 36.05375, longitude: -112.08409),
    .init(latitude: 36.05375, longitude: -112.08408),
    .init(latitude: 36.05372, longitude: -112.08403),
    .init(latitude: 36.0537, longitude: -112.08398),
    .init(latitude: 36.05369, longitude: -112.08393),
    .init(latitude: 36.05368, longitude: -112.08388),
    .init(latitude: 36.05367, longitude: -112.08382),
    .init(latitude: 36.05366, longitude: -112.08377),
    .init(latitude: 36.05367, longitude: -112.08371),
    .init(latitude: 36.0537, longitude: -112.0837),
    .init(latitude: 36.0537, longitude: -112.08371),
    .init(latitude: 36.05369, longitude: -112.08377),
    .init(latitude: 36.0537, longitude: -112.08383),
    .init(latitude: 36.05372, longitude: -112.08388),
    .init(latitude: 36.05375, longitude: -112.08393),
    .init(latitude: 36.05378, longitude: -112.08397),
    .init(latitude: 36.05381, longitude: -112.084),
    .init(latitude: 36.05385, longitude: -112.08401),
    .init(latitude: 36.05388, longitude: -112.08399),
    .init(latitude: 36.05388, longitude: -112.08397),
    .init(latitude: 36.05384, longitude: -112.08393),
    .init(latitude: 36.05381, longitude: -112.08388),
    .init(latitude: 36.05381, longitude: -112.08386),
    .init(latitude: 36.05385, longitude: -112.0839),
    .init(latitude: 36.05388, longitude: -112.08394),
    .init(latitude: 36.05392, longitude: -112.08397),
    .init(latitude: 36.05391, longitude: -112.08395),
    .init(latitude: 36.05389, longitude: -112.0839),
    .init(latitude: 36.05389, longitude: -112.08384),
    .init(latitude: 36.05393, longitude: -112.08381),
    .init(latitude: 36.05397, longitude: -112.08379),
    .init(latitude: 36.05398, longitude: -112.0838),
    .init(latitude: 36.05396, longitude: -112.08385),
    .init(latitude: 36.05396, longitude: -112.08391),
    .init(latitude: 36.05396, longitude: -112.08396),
    .init(latitude: 36.05397, longitude: -112.08397),
    .init(latitude: 36.05401, longitude: -112.08394),
    .init(latitude: 36.05403, longitude: -112.08392),
    .init(latitude: 36.05412, longitude: -112.08385),
    .init(latitude: 36.05417, longitude: -112.08383),
    .init(latitude: 36.05421, longitude: -112.08381),
    .init(latitude: 36.05426, longitude: -112.0838),
    .init(latitude: 36.05431, longitude: -112.0838),
    .init(latitude: 36.05436, longitude: -112.08379),
    .init(latitude: 36.0544, longitude: -112.08379),
    .init(latitude: 36.05444, longitude: -112.08376),
    .init(latitude: 36.05449, longitude: -112.08375),
    .init(latitude: 36.05454, longitude: -112.08376),
    .init(latitude: 36.05458, longitude: -112.08378),
    .init(latitude: 36.05463, longitude: -112.08379),
    .init(latitude: 36.05467, longitude: -112.08377),
    .init(latitude: 36.05472, longitude: -112.08375),
    .init(latitude: 36.05476, longitude: -112.08374),
    .init(latitude: 36.05481, longitude: -112.08374),
    .init(latitude: 36.05486, longitude: -112.08374),
    .init(latitude: 36.0549, longitude: -112.08375),
    .init(latitude: 36.05495, longitude: -112.08377),
    .init(latitude: 36.055, longitude: -112.08379),
    .init(latitude: 36.05504, longitude: -112.08382),
    .init(latitude: 36.05508, longitude: -112.08385),
    .init(latitude: 36.05512, longitude: -112.08388),
    .init(latitude: 36.05516, longitude: -112.08391),
    .init(latitude: 36.05521, longitude: -112.08392),
    .init(latitude: 36.05525, longitude: -112.08393),
    .init(latitude: 36.0553, longitude: -112.08395),
    .init(latitude: 36.05534, longitude: -112.08396),
    .init(latitude: 36.0554, longitude: -112.08397),
    .init(latitude: 36.05544, longitude: -112.08398),
    .init(latitude: 36.05549, longitude: -112.08399),
    .init(latitude: 36.05551, longitude: -112.084),
    .init(latitude: 36.05561, longitude: -112.08399),
    .init(latitude: 36.05565, longitude: -112.08399),
    .init(latitude: 36.0557, longitude: -112.084),
    .init(latitude: 36.05575, longitude: -112.08402),
    .init(latitude: 36.05579, longitude: -112.08403),
    .init(latitude: 36.05584, longitude: -112.08404),
    .init(latitude: 36.05588, longitude: -112.08404),
    .init(latitude: 36.05593, longitude: -112.08404),
    .init(latitude: 36.05598, longitude: -112.08404),
    .init(latitude: 36.05603, longitude: -112.08403),
    .init(latitude: 36.05608, longitude: -112.08403),
    .init(latitude: 36.05612, longitude: -112.08404),
    .init(latitude: 36.05617, longitude: -112.08405),
    .init(latitude: 36.05622, longitude: -112.08407),
    .init(latitude: 36.05626, longitude: -112.08409),
    .init(latitude: 36.05631, longitude: -112.08412),
    .init(latitude: 36.05635, longitude: -112.08414),
    .init(latitude: 36.05639, longitude: -112.08417),
    .init(latitude: 36.05642, longitude: -112.08422),
    .init(latitude: 36.05645, longitude: -112.08427),
    .init(latitude: 36.05648, longitude: -112.08431),
    .init(latitude: 36.05651, longitude: -112.08436),
    .init(latitude: 36.05655, longitude: -112.08441),
    .init(latitude: 36.05658, longitude: -112.08445),
    .init(latitude: 36.05661, longitude: -112.0845),
    .init(latitude: 36.05664, longitude: -112.08453),
    .init(latitude: 36.05669, longitude: -112.08455),
    .init(latitude: 36.05674, longitude: -112.08457),
    .init(latitude: 36.05679, longitude: -112.08457),
    .init(latitude: 36.05683, longitude: -112.08457),
    .init(latitude: 36.05688, longitude: -112.08458),
    .init(latitude: 36.05692, longitude: -112.08461),
    .init(latitude: 36.05696, longitude: -112.08462),
    .init(latitude: 36.057, longitude: -112.08463),
    .init(latitude: 36.05716, longitude: -112.08467),
    .init(latitude: 36.05722, longitude: -112.08469),
    .init(latitude: 36.05726, longitude: -112.08471),
    .init(latitude: 36.05731, longitude: -112.08473),
    .init(latitude: 36.05735, longitude: -112.08476),
    .init(latitude: 36.05738, longitude: -112.08481),
    .init(latitude: 36.05742, longitude: -112.08483),
    .init(latitude: 36.05747, longitude: -112.08483),
    .init(latitude: 36.05751, longitude: -112.08481),
    .init(latitude: 36.05755, longitude: -112.0848),
    .init(latitude: 36.0576, longitude: -112.08477),
    .init(latitude: 36.05764, longitude: -112.08476),
    .init(latitude: 36.05769, longitude: -112.08475),
    .init(latitude: 36.05774, longitude: -112.08475),
    .init(latitude: 36.05778, longitude: -112.08477),
    .init(latitude: 36.05783, longitude: -112.08479),
    .init(latitude: 36.05787, longitude: -112.0848),
    .init(latitude: 36.05792, longitude: -112.0848),
    .init(latitude: 36.05797, longitude: -112.08477),
    .init(latitude: 36.05803, longitude: -112.08476),
    .init(latitude: 36.05808, longitude: -112.08475),
    .init(latitude: 36.05813, longitude: -112.08475),
    .init(latitude: 36.05817, longitude: -112.08475),
    .init(latitude: 36.05822, longitude: -112.08476),
    .init(latitude: 36.05826, longitude: -112.08479),
    .init(latitude: 36.0583, longitude: -112.08483),
    .init(latitude: 36.05833, longitude: -112.08488),
    .init(latitude: 36.05837, longitude: -112.08492),
    .init(latitude: 36.05839, longitude: -112.08497),
    .init(latitude: 36.05842, longitude: -112.08503),
    .init(latitude: 36.05843, longitude: -112.08508),
    .init(latitude: 36.05846, longitude: -112.08513),
    .init(latitude: 36.0585, longitude: -112.08516),
    .init(latitude: 36.05855, longitude: -112.08518),
    .init(latitude: 36.05859, longitude: -112.0852),
    .init(latitude: 36.05864, longitude: -112.08521),
    .init(latitude: 36.05869, longitude: -112.08521),
    .init(latitude: 36.05874, longitude: -112.08521),
    .init(latitude: 36.05878, longitude: -112.08521),
    .init(latitude: 36.05879, longitude: -112.08521),
    .init(latitude: 36.05889, longitude: -112.08519),
    .init(latitude: 36.05893, longitude: -112.08518),
    .init(latitude: 36.05897, longitude: -112.08515),
    .init(latitude: 36.05902, longitude: -112.08515),
    .init(latitude: 36.05906, longitude: -112.08517),
    .init(latitude: 36.0591, longitude: -112.0852),
    .init(latitude: 36.05914, longitude: -112.08523),
    .init(latitude: 36.05917, longitude: -112.08528),
    .init(latitude: 36.05919, longitude: -112.08533),
    .init(latitude: 36.05923, longitude: -112.08536),
    .init(latitude: 36.05926, longitude: -112.08541),
    .init(latitude: 36.05928, longitude: -112.08546),
    .init(latitude: 36.05932, longitude: -112.0855),
    .init(latitude: 36.05936, longitude: -112.08554),
    .init(latitude: 36.05938, longitude: -112.08559),
    .init(latitude: 36.05939, longitude: -112.08565),
    .init(latitude: 36.05938, longitude: -112.0857),
    .init(latitude: 36.05938, longitude: -112.08576),
    .init(latitude: 36.05938, longitude: -112.08582),
    .init(latitude: 36.05939, longitude: -112.08588),
    .init(latitude: 36.05941, longitude: -112.08594),
    .init(latitude: 36.05943, longitude: -112.08599),
    .init(latitude: 36.05946, longitude: -112.08604),
    .init(latitude: 36.0595, longitude: -112.08607),
    .init(latitude: 36.05954, longitude: -112.0861),
    .init(latitude: 36.05958, longitude: -112.08614),
    .init(latitude: 36.05962, longitude: -112.08617),
    .init(latitude: 36.05967, longitude: -112.08619),
    .init(latitude: 36.05971, longitude: -112.0862),
    .init(latitude: 36.05975, longitude: -112.08623),
    .init(latitude: 36.0598, longitude: -112.08624),
    .init(latitude: 36.05984, longitude: -112.08628),
    .init(latitude: 36.05988, longitude: -112.08629),
    .init(latitude: 36.05992, longitude: -112.08632),
    .init(latitude: 36.05996, longitude: -112.08635),
    .init(latitude: 36.06, longitude: -112.08639),
    .init(latitude: 36.06004, longitude: -112.08642),
    .init(latitude: 36.06007, longitude: -112.08645),
    .init(latitude: 36.06012, longitude: -112.08646),
    .init(latitude: 36.06016, longitude: -112.0865),
    .init(latitude: 36.06021, longitude: -112.08653),
    .init(latitude: 36.06025, longitude: -112.08657),
    .init(latitude: 36.06029, longitude: -112.08659),
    .init(latitude: 36.06034, longitude: -112.08661),
    .init(latitude: 36.06038, longitude: -112.08661),
    .init(latitude: 36.06043, longitude: -112.08661),
    .init(latitude: 36.06048, longitude: -112.08659),
    .init(latitude: 36.06052, longitude: -112.08657),
    .init(latitude: 36.06054, longitude: -112.08656),
    .init(latitude: 36.06058, longitude: -112.08652),
    .init(latitude: 36.06061, longitude: -112.08647),
    .init(latitude: 36.06065, longitude: -112.08644),
    .init(latitude: 36.0607, longitude: -112.08641),
    .init(latitude: 36.06074, longitude: -112.08641),
    .init(latitude: 36.06079, longitude: -112.08642),
    .init(latitude: 36.06084, longitude: -112.08643),
    .init(latitude: 36.06089, longitude: -112.08644),
    .init(latitude: 36.06093, longitude: -112.08645),
    .init(latitude: 36.06097, longitude: -112.08648),
    .init(latitude: 36.06101, longitude: -112.08652),
    .init(latitude: 36.06105, longitude: -112.08655),
    .init(latitude: 36.06109, longitude: -112.08657),
    .init(latitude: 36.06114, longitude: -112.08659),
    .init(latitude: 36.06118, longitude: -112.08662),
    .init(latitude: 36.06121, longitude: -112.08666),
    .init(latitude: 36.06125, longitude: -112.08671),
    .init(latitude: 36.06129, longitude: -112.08674),
    .init(latitude: 36.06132, longitude: -112.08678),
    .init(latitude: 36.06135, longitude: -112.08683),
    .init(latitude: 36.06139, longitude: -112.08687),
    .init(latitude: 36.06143, longitude: -112.08691),
    .init(latitude: 36.06145, longitude: -112.08696),
    .init(latitude: 36.06148, longitude: -112.08701),
    .init(latitude: 36.0615, longitude: -112.08704),
    .init(latitude: 36.06148, longitude: -112.08701),
    .init(latitude: 36.06145, longitude: -112.08696),
    .init(latitude: 36.06143, longitude: -112.08691),
    .init(latitude: 36.06139, longitude: -112.08687),
    .init(latitude: 36.06135, longitude: -112.08683),
    .init(latitude: 36.06132, longitude: -112.08678),
    .init(latitude: 36.06129, longitude: -112.08674),
    .init(latitude: 36.06125, longitude: -112.08671),
    .init(latitude: 36.06121, longitude: -112.08666),
    .init(latitude: 36.06118, longitude: -112.08662),
    .init(latitude: 36.06114, longitude: -112.08659),
    .init(latitude: 36.06109, longitude: -112.08657),
    .init(latitude: 36.06105, longitude: -112.08655),
    .init(latitude: 36.06101, longitude: -112.08652),
    .init(latitude: 36.06097, longitude: -112.08648),
    .init(latitude: 36.06093, longitude: -112.08645),
    .init(latitude: 36.06089, longitude: -112.08644),
    .init(latitude: 36.06084, longitude: -112.08643),
    .init(latitude: 36.06079, longitude: -112.08642),
    .init(latitude: 36.06074, longitude: -112.08641),
    .init(latitude: 36.0607, longitude: -112.08641),
    .init(latitude: 36.06065, longitude: -112.08644),
    .init(latitude: 36.06061, longitude: -112.08647),
    .init(latitude: 36.06058, longitude: -112.08652),
    .init(latitude: 36.06054, longitude: -112.08656),
    .init(latitude: 36.06052, longitude: -112.08657),
    .init(latitude: 36.06048, longitude: -112.08659),
    .init(latitude: 36.06043, longitude: -112.08661),
    .init(latitude: 36.06038, longitude: -112.08661),
    .init(latitude: 36.06034, longitude: -112.08661),
    .init(latitude: 36.06029, longitude: -112.08659),
    .init(latitude: 36.06025, longitude: -112.08657),
    .init(latitude: 36.06021, longitude: -112.08653),
    .init(latitude: 36.06016, longitude: -112.0865),
    .init(latitude: 36.06012, longitude: -112.08646),
    .init(latitude: 36.06007, longitude: -112.08645),
    .init(latitude: 36.06004, longitude: -112.08642),
    .init(latitude: 36.06, longitude: -112.08639),
    .init(latitude: 36.05996, longitude: -112.08635),
    .init(latitude: 36.05992, longitude: -112.08632),
    .init(latitude: 36.05988, longitude: -112.08629),
    .init(latitude: 36.05984, longitude: -112.08628),
    .init(latitude: 36.0598, longitude: -112.08624),
    .init(latitude: 36.05975, longitude: -112.08623),
    .init(latitude: 36.05971, longitude: -112.0862),
    .init(latitude: 36.05967, longitude: -112.08619),
    .init(latitude: 36.05962, longitude: -112.08617),
    .init(latitude: 36.05958, longitude: -112.08614),
    .init(latitude: 36.05954, longitude: -112.0861),
    .init(latitude: 36.0595, longitude: -112.08607),
    .init(latitude: 36.05946, longitude: -112.08604),
    .init(latitude: 36.05943, longitude: -112.08599),
    .init(latitude: 36.05941, longitude: -112.08594),
    .init(latitude: 36.05939, longitude: -112.08588),
    .init(latitude: 36.05938, longitude: -112.08582),
    .init(latitude: 36.05938, longitude: -112.08576),
    .init(latitude: 36.05938, longitude: -112.0857),
    .init(latitude: 36.05939, longitude: -112.08565),
    .init(latitude: 36.05938, longitude: -112.08559),
    .init(latitude: 36.05936, longitude: -112.08554),
    .init(latitude: 36.05932, longitude: -112.0855),
    .init(latitude: 36.05928, longitude: -112.08546),
    .init(latitude: 36.05926, longitude: -112.08541),
    .init(latitude: 36.05923, longitude: -112.08536),
    .init(latitude: 36.05919, longitude: -112.08533),
    .init(latitude: 36.05917, longitude: -112.08528),
    .init(latitude: 36.05914, longitude: -112.08523),
    .init(latitude: 36.0591, longitude: -112.0852),
    .init(latitude: 36.05906, longitude: -112.08517),
    .init(latitude: 36.05902, longitude: -112.08515),
    .init(latitude: 36.05897, longitude: -112.08515),
    .init(latitude: 36.05893, longitude: -112.08518),
    .init(latitude: 36.05889, longitude: -112.08519),
    .init(latitude: 36.05879, longitude: -112.08521),
    .init(latitude: 36.05878, longitude: -112.08521),
    .init(latitude: 36.05874, longitude: -112.08521),
    .init(latitude: 36.05869, longitude: -112.08521),
    .init(latitude: 36.05864, longitude: -112.08521),
    .init(latitude: 36.05859, longitude: -112.0852),
    .init(latitude: 36.05855, longitude: -112.08518),
    .init(latitude: 36.0585, longitude: -112.08516),
    .init(latitude: 36.05846, longitude: -112.08513),
    .init(latitude: 36.05843, longitude: -112.08508),
    .init(latitude: 36.05842, longitude: -112.08503),
    .init(latitude: 36.05839, longitude: -112.08497),
    .init(latitude: 36.05837, longitude: -112.08492),
    .init(latitude: 36.05833, longitude: -112.08488),
    .init(latitude: 36.0583, longitude: -112.08483),
    .init(latitude: 36.05826, longitude: -112.08479),
    .init(latitude: 36.05822, longitude: -112.08476),
    .init(latitude: 36.05817, longitude: -112.08475),
    .init(latitude: 36.05813, longitude: -112.08475),
    .init(latitude: 36.05808, longitude: -112.08475),
    .init(latitude: 36.05803, longitude: -112.08476),
    .init(latitude: 36.05797, longitude: -112.08477),
    .init(latitude: 36.05792, longitude: -112.0848),
    .init(latitude: 36.05787, longitude: -112.0848),
    .init(latitude: 36.05783, longitude: -112.08479),
    .init(latitude: 36.05778, longitude: -112.08477),
    .init(latitude: 36.05774, longitude: -112.08475),
    .init(latitude: 36.05769, longitude: -112.08475),
    .init(latitude: 36.05764, longitude: -112.08476),
    .init(latitude: 36.0576, longitude: -112.08477),
    .init(latitude: 36.05755, longitude: -112.0848),
    .init(latitude: 36.05751, longitude: -112.08481),
    .init(latitude: 36.05747, longitude: -112.08483),
    .init(latitude: 36.05742, longitude: -112.08483),
    .init(latitude: 36.05738, longitude: -112.08481),
    .init(latitude: 36.05735, longitude: -112.08476),
    .init(latitude: 36.05731, longitude: -112.08473),
    .init(latitude: 36.05726, longitude: -112.08471),
    .init(latitude: 36.05722, longitude: -112.08469),
    .init(latitude: 36.05716, longitude: -112.08467),
    .init(latitude: 36.057, longitude: -112.08463),
    .init(latitude: 36.05696, longitude: -112.08462),
    .init(latitude: 36.05692, longitude: -112.08461),
    .init(latitude: 36.05688, longitude: -112.08458),
    .init(latitude: 36.05683, longitude: -112.08457),
    .init(latitude: 36.05679, longitude: -112.08457),
    .init(latitude: 36.05674, longitude: -112.08457),
    .init(latitude: 36.05669, longitude: -112.08455),
    .init(latitude: 36.05664, longitude: -112.08453),
    .init(latitude: 36.05661, longitude: -112.0845),
    .init(latitude: 36.05658, longitude: -112.08445),
    .init(latitude: 36.05655, longitude: -112.08441),
    .init(latitude: 36.05651, longitude: -112.08436),
    .init(latitude: 36.05648, longitude: -112.08431),
    .init(latitude: 36.05645, longitude: -112.08427),
    .init(latitude: 36.05642, longitude: -112.08422),
    .init(latitude: 36.05639, longitude: -112.08417),
    .init(latitude: 36.05635, longitude: -112.08414),
    .init(latitude: 36.05631, longitude: -112.08412),
    .init(latitude: 36.05626, longitude: -112.08409),
    .init(latitude: 36.05622, longitude: -112.08407),
    .init(latitude: 36.05617, longitude: -112.08405),
    .init(latitude: 36.05612, longitude: -112.08404),
    .init(latitude: 36.05608, longitude: -112.08403),
    .init(latitude: 36.05603, longitude: -112.08403),
    .init(latitude: 36.05598, longitude: -112.08404),
    .init(latitude: 36.05593, longitude: -112.08404),
    .init(latitude: 36.05588, longitude: -112.08404),
    .init(latitude: 36.05584, longitude: -112.08404),
    .init(latitude: 36.05579, longitude: -112.08403),
    .init(latitude: 36.05575, longitude: -112.08402),
    .init(latitude: 36.0557, longitude: -112.084),
    .init(latitude: 36.05565, longitude: -112.08399),
    .init(latitude: 36.05561, longitude: -112.08399),
    .init(latitude: 36.05551, longitude: -112.084),
    .init(latitude: 36.05549, longitude: -112.08399),
    .init(latitude: 36.05544, longitude: -112.08398),
    .init(latitude: 36.0554, longitude: -112.08397),
    .init(latitude: 36.05534, longitude: -112.08396),
    .init(latitude: 36.0553, longitude: -112.08395),
    .init(latitude: 36.05525, longitude: -112.08393),
    .init(latitude: 36.05521, longitude: -112.08392),
    .init(latitude: 36.05516, longitude: -112.08391),
    .init(latitude: 36.05512, longitude: -112.08388),
    .init(latitude: 36.05508, longitude: -112.08385),
    .init(latitude: 36.05504, longitude: -112.08382),
    .init(latitude: 36.055, longitude: -112.08379),
    .init(latitude: 36.05495, longitude: -112.08377),
    .init(latitude: 36.0549, longitude: -112.08375),
    .init(latitude: 36.05486, longitude: -112.08374),
    .init(latitude: 36.05481, longitude: -112.08374),
    .init(latitude: 36.05476, longitude: -112.08374),
    .init(latitude: 36.05472, longitude: -112.08375),
    .init(latitude: 36.05467, longitude: -112.08377),
    .init(latitude: 36.05463, longitude: -112.08379),
    .init(latitude: 36.05458, longitude: -112.08378),
    .init(latitude: 36.05454, longitude: -112.08376),
    .init(latitude: 36.05449, longitude: -112.08375),
    .init(latitude: 36.05444, longitude: -112.08376),
    .init(latitude: 36.0544, longitude: -112.08379),
    .init(latitude: 36.05436, longitude: -112.08379),
    .init(latitude: 36.05431, longitude: -112.0838),
    .init(latitude: 36.05426, longitude: -112.0838),
    .init(latitude: 36.05421, longitude: -112.08381),
    .init(latitude: 36.05417, longitude: -112.08383),
    .init(latitude: 36.05412, longitude: -112.08385),
    .init(latitude: 36.05403, longitude: -112.08392),
    .init(latitude: 36.05401, longitude: -112.08394),
    .init(latitude: 36.05397, longitude: -112.08397),
    .init(latitude: 36.05396, longitude: -112.08396),
    .init(latitude: 36.05396, longitude: -112.08391),
    .init(latitude: 36.05396, longitude: -112.08385),
    .init(latitude: 36.05398, longitude: -112.0838),
    .init(latitude: 36.05397, longitude: -112.08379),
    .init(latitude: 36.05393, longitude: -112.08381),
    .init(latitude: 36.05389, longitude: -112.08384),
    .init(latitude: 36.05389, longitude: -112.0839),
    .init(latitude: 36.05391, longitude: -112.08395),
    .init(latitude: 36.05392, longitude: -112.08397),
    .init(latitude: 36.05388, longitude: -112.08394),
    .init(latitude: 36.05385, longitude: -112.0839),
    .init(latitude: 36.05381, longitude: -112.08386),
    .init(latitude: 36.05381, longitude: -112.08388),
    .init(latitude: 36.05384, longitude: -112.08393),
    .init(latitude: 36.05388, longitude: -112.08397),
    .init(latitude: 36.05388, longitude: -112.08399),
    .init(latitude: 36.05385, longitude: -112.08401),
    .init(latitude: 36.05381, longitude: -112.084),
    .init(latitude: 36.05378, longitude: -112.08397),
    .init(latitude: 36.05375, longitude: -112.08393),
    .init(latitude: 36.05372, longitude: -112.08388),
    .init(latitude: 36.0537, longitude: -112.08383),
    .init(latitude: 36.05369, longitude: -112.08377),
    .init(latitude: 36.0537, longitude: -112.08371),
    .init(latitude: 36.0537, longitude: -112.0837),
    .init(latitude: 36.05367, longitude: -112.08371),
    .init(latitude: 36.05366, longitude: -112.08377),
    .init(latitude: 36.05367, longitude: -112.08382),
    .init(latitude: 36.05368, longitude: -112.08388),
    .init(latitude: 36.05369, longitude: -112.08393),
    .init(latitude: 36.0537, longitude: -112.08398),
    .init(latitude: 36.05372, longitude: -112.08403),
    .init(latitude: 36.05375, longitude: -112.08408),
    .init(latitude: 36.05375, longitude: -112.08409),
    .init(latitude: 36.05372, longitude: -112.08408),
    .init(latitude: 36.05369, longitude: -112.08404),
    .init(latitude: 36.05367, longitude: -112.08399),
    .init(latitude: 36.05366, longitude: -112.08393),
    .init(latitude: 36.05363, longitude: -112.08389),
    .init(latitude: 36.0536, longitude: -112.08385),
    .init(latitude: 36.05358, longitude: -112.0838),
    .init(latitude: 36.05358, longitude: -112.08374),
    .init(latitude: 36.05359, longitude: -112.08368),
    .init(latitude: 36.05359, longitude: -112.08363),
    .init(latitude: 36.05361, longitude: -112.08357),
    .init(latitude: 36.05364, longitude: -112.08355),
    .init(latitude: 36.05365, longitude: -112.08355),
    .init(latitude: 36.05369, longitude: -112.08354),
    .init(latitude: 36.0537, longitude: -112.08351),
    .init(latitude: 36.0537, longitude: -112.08347),
    .init(latitude: 36.05368, longitude: -112.08342),
    .init(latitude: 36.05368, longitude: -112.08336),
    .init(latitude: 36.0537, longitude: -112.08331),
    .init(latitude: 36.05375, longitude: -112.08328),
    .init(latitude: 36.05379, longitude: -112.08327),
    .init(latitude: 36.05383, longitude: -112.08324),
    .init(latitude: 36.05384, longitude: -112.0832),
    .init(latitude: 36.05383, longitude: -112.0832),
    .init(latitude: 36.05379, longitude: -112.08319),
    .init(latitude: 36.05374, longitude: -112.08321),
    .init(latitude: 36.0537, longitude: -112.08324),
    .init(latitude: 36.05366, longitude: -112.08327),
    .init(latitude: 36.05362, longitude: -112.0833),
    .init(latitude: 36.0536, longitude: -112.08335),
    .init(latitude: 36.05356, longitude: -112.08338),
    .init(latitude: 36.05353, longitude: -112.08343),
    .init(latitude: 36.05351, longitude: -112.08347),
    .init(latitude: 36.05348, longitude: -112.08352),
    .init(latitude: 36.05347, longitude: -112.08357),
    .init(latitude: 36.05346, longitude: -112.08363),
    .init(latitude: 36.05344, longitude: -112.08368),
    .init(latitude: 36.05341, longitude: -112.08372),
    .init(latitude: 36.05336, longitude: -112.08374),
    .init(latitude: 36.05332, longitude: -112.08377),
    .init(latitude: 36.05328, longitude: -112.08381),
    .init(latitude: 36.05326, longitude: -112.08386),
    .init(latitude: 36.05325, longitude: -112.08391),
    .init(latitude: 36.05324, longitude: -112.08396),
    .init(latitude: 36.05321, longitude: -112.08401),
    .init(latitude: 36.05319, longitude: -112.08406),
    .init(latitude: 36.05314, longitude: -112.08408),
    .init(latitude: 36.0531, longitude: -112.08409),
    .init(latitude: 36.05305, longitude: -112.08408),
    .init(latitude: 36.05301, longitude: -112.08405),
    .init(latitude: 36.05297, longitude: -112.08402),
    .init(latitude: 36.05293, longitude: -112.08394)
]
