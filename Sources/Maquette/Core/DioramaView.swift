import CoreLocation
import SwiftUI

/// The primary public interface for displaying a 3D diorama.
///
/// `DioramaView` works identically on visionOS, iOS, iPadOS, and macOS, automatically selecting
/// the appropriate rendering and interaction mode for each platform. Its shape follows MapKit's
/// SwiftUI interface: the init carries *place and interaction*, modifiers carry *style and
/// observation*, and a result builder carries *content*.
///
/// **Minimal usage:**
/// ```swift
/// import Maquette
///
/// DioramaView(region: DioramaRegion(
///     center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
///     radius: 1500
/// ))
/// ```
///
/// **With style, content, and a camera binding:**
/// ```swift
/// @State private var position: DioramaCameraPosition = .automatic
///
/// DioramaView(region: canyon, position: $position) {
///     DioramaMarker("Grand Canyon", coordinate: rim, tint: .red)
///     DioramaPolyline(coordinates: trail, tint: .blue)
/// }
/// .dioramaStyle(.standard(chunk: .canyon, panRange: 0.6))
/// .dioramaEffect(.ink)
/// ```
///
/// **Or straight from GeoJSON:**
/// ```swift
/// let park = try JSONDecoder().decode(FeatureCollection.self, from: data)
/// if let region = DioramaRegion(fitting: park), let shape = DioramaShape.geoJSON(park) {
///     DioramaView(region: region, shape: shape) { park }
/// }
/// ```
///
/// The region is live: handing the view a different one relocates or reloads the diorama in
/// place, and so does a changed ``DioramaStyle`` — no identity tricks required.
public struct DioramaView: View {
    let region: DioramaRegion
    let shape: DioramaShape
    let physicalSize: Float
    let interactionModes: DioramaInteractionModes
    let position: Binding<DioramaCameraPosition>?
    let selection: Binding<DioramaAnnotation.ID?>?
    let content: DioramaContentGroup

    @Environment(\.dioramaStyle) private var style

    /// Creates a diorama view.
    ///
    /// - Parameters:
    ///   - region: Where on Earth the diorama shows. Live — changing it moves the diorama.
    ///   - shape: The outline the chunk is cut to. Defaults to circular.
    ///   - physicalSize: The diorama's largest horizontal span in physical meters — real-world
    ///     size on visionOS, a viewport reference on iOS and macOS.
    ///   - interactionModes: Which gestures the view responds to.
    ///   - position: A camera request-and-read-back binding, the parallel of `MapCameraPosition`.
    ///     `nil` leaves the framework framing the chunk. Ignored on visionOS, which has no camera.
    ///   - selection: The selected marker's identity, written on tap. `nil` disables selection.
    ///   - content: Markers, polylines, features, and route previews to place on the diorama.
    public init(
        region: DioramaRegion,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<DioramaAnnotation.ID?>? = nil,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.region = region
        self.shape = shape
        self.physicalSize = physicalSize
        self.interactionModes = interactionModes
        self.position = position
        self.selection = selection
        self.content = content()
    }

    public var body: some View {
        let inputs = DioramaViewInputs(
            region: region,
            shape: shape,
            physicalSize: physicalSize,
            style: style,
            interactionModes: interactionModes,
            position: position,
            selection: selection,
            content: content
        )
        #if os(visionOS)
        VisionOSDioramaView(inputs: inputs)
        #elseif os(iOS)
        IOSDioramaView(inputs: inputs)
        #elseif os(macOS)
        MacOSDioramaView(inputs: inputs)
        #else
        // RealityKit's RealityView does not exist on this platform, so there is nothing to render
        // with. Degrading at runtime rather than failing to compile keeps a multi-platform target
        // that merely *links* Maquette buildable.
        ContentUnavailableView(
            "Unsupported Platform",
            systemImage: "cube.transparent",
            description: Text("Maquette requires RealityKit, which is available on iOS, iPadOS, macOS, and visionOS.")
        )
        #endif
    }
}

/// Everything a platform view receives from the public façade, in one carrier.
struct DioramaViewInputs {
    var region: DioramaRegion
    var shape: DioramaShape
    var physicalSize: Float
    var style: DioramaStyle
    var interactionModes: DioramaInteractionModes
    var position: Binding<DioramaCameraPosition>?
    var selection: Binding<DioramaAnnotation.ID?>?
    var content: DioramaContentGroup

    /// The configuration the pipelines consume, assembled from the public vocabulary.
    var configuration: DioramaConfiguration {
        DioramaConfiguration(region: region, shape: shape, physicalSize: physicalSize, style: style)
    }

    /// The subset whose change means the substrate must relocate or reload.
    struct ReloadKey: Equatable {
        var region: DioramaRegion
        var shape: DioramaShape
        var physicalSize: Float
        var style: DioramaStyle
    }

    var reloadKey: ReloadKey {
        ReloadKey(region: region, shape: shape, physicalSize: physicalSize, style: style)
    }
}
