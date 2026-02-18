import CoreLocation
import SwiftUI

/// The primary public interface for displaying a 3D diorama.
///
/// `DioramaView` works identically on visionOS, iOS, iPadOS, and macOS, automatically
/// selecting the appropriate rendering and interaction mode for each platform.
///
/// **Minimal usage:**
/// ```swift
/// import Maquette
///
/// DioramaView(
///     center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
///     radius: 1500
/// )
/// ```
///
/// **Full configuration:**
/// ```swift
/// DioramaView(
///     configuration: DioramaConfiguration(
///         center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
///         radiusMeters: 5000,
///         elevation: .realistic,
///         shape: .circular,
///         physicalDiameter: 0.8,
///         elevationExaggeration: 1.0
///     )
/// )
/// ```
///
/// **MapTiler high-resolution satellite:**
/// ```swift
/// DioramaView(
///     configuration: DioramaConfiguration(
///         center: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
///         radiusMeters: 5000,
///         imagerySource: .mapTilerSatellite(apiKey: "your-key")
///     )
/// )
/// ```
///
/// **Google Photorealistic 3D Tiles:**
/// ```swift
/// DioramaView(
///     configuration: DioramaConfiguration(
///         center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
///         radiusMeters: 1500,
///         imagerySource: .photorealistic(
///             provider: GoogleTiles3DProvider(apiKey: "your-google-key")
///         )
///     )
/// )
/// ```
public struct DioramaView<Annotations: View>: View {
    let configuration: DioramaConfiguration
    let annotations: ((DioramaProxy) -> Annotations)?

    /// Creates a diorama view with full configuration and optional annotations.
    public init(
        configuration: DioramaConfiguration,
        @ViewBuilder annotations: @escaping (DioramaProxy) -> Annotations
    ) {
        self.configuration = configuration
        self.annotations = annotations
    }

    /// Creates a diorama view with a center coordinate and radius.
    public init(
        center: CLLocationCoordinate2D,
        radius: Double
    ) where Annotations == EmptyView {
        self.configuration = DioramaConfiguration(center: center, radiusMeters: radius)
        self.annotations = nil
    }

    /// Creates a diorama view with full configuration and no annotations.
    public init(
        configuration: DioramaConfiguration
    ) where Annotations == EmptyView {
        self.configuration = configuration
        self.annotations = nil
    }

    public var body: some View {
        #if os(visionOS)
        VisionOSDioramaView(configuration: configuration, annotations: annotations)
        #elseif os(iOS)
        IOSDioramaView(configuration: configuration, annotations: annotations)
        #elseif os(macOS)
        MacOSDioramaView(configuration: configuration, annotations: annotations)
        #endif
    }
}
