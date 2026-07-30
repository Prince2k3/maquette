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
/// **With annotations:**
/// ```swift
/// DioramaView(configuration: config) {
///     DioramaAnnotation.marker(
///         at: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
///         tint: .red,
///         title: "Grand Canyon"
///     )
///
///     DioramaAnnotation.line(through: [coord1, coord2, coord3], tint: .blue)
/// }
/// ```
///
/// **Or straight from GeoJSON:**
/// ```swift
/// let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
/// DioramaView(configuration: config) {
///     collection
/// }
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
public struct DioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    /// Creates a diorama view with full configuration and content (markers, polylines).
    public init(
        configuration: DioramaConfiguration,
        @DioramaContentBuilder content: () -> DioramaContentGroup
    ) {
        self.configuration = configuration
        self.content = content()
    }

    /// Creates a diorama view with full configuration and no content.
    public init(configuration: DioramaConfiguration) {
        self.configuration = configuration
        self.content = nil
    }

    /// Creates a diorama view with a center coordinate and radius.
    public init(center: CLLocationCoordinate2D, radius: Double) {
        self.configuration = DioramaConfiguration(center: center, radiusMeters: radius)
        self.content = nil
    }

    public var body: some View {
        #if os(visionOS)
        VisionOSDioramaView(configuration: configuration, content: content)
        #elseif os(iOS)
        IOSDioramaView(configuration: configuration, content: content)
        #elseif os(macOS)
        MacOSDioramaView(configuration: configuration, content: content)
        #endif
    }
}
