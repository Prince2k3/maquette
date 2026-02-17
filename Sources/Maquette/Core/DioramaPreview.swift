import CoreLocation
import SwiftUI

// MARK: - Previews

#Preview("Grand Canyon — Rim to Rim") {
    DioramaView(
        configuration: DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
            radiusMeters: 5000
        )
    )
    .frame(minWidth: 400, minHeight: 400)
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

// Uncomment and add your Cesium ion access token to test Cesium 3D tiles:
//
// #Preview("Cesium Ion 3D Tiles — Grand Canyon") {
//     DioramaView(
//         configuration: DioramaConfiguration(
//             center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
//             radiusMeters: 5000,
//             imagerySource: .photorealistic(
//                 provider: CesiumIonTiles3DProvider(
//                     accessToken: "YOUR_CESIUM_TOKEN",
//                     assetId: 2275207
//                 )
//             )
//         )
//     )
//     .frame(minWidth: 400, minHeight: 400)
// }
