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
    let selection: DioramaSelection?
    let content: DioramaContentGroup
    private var groundPosition: Binding<DioramaGroundPosition>?
    @State private var startupRegion: DioramaRegion?

    @Environment(\.dioramaStyle) private var style
    @Environment(\.dioramaShapeOverride) private var shapeOverride
    @Environment(\.dioramaPhysicalSizeOverride) private var physicalSizeOverride
    @Environment(\.dioramaLoadingPolicy) private var loadingPolicy

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
        selection: Binding<DioramaFeature.ID?>? = nil,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.region = region
        self.shape = shape
        self.physicalSize = physicalSize
        self.interactionModes = interactionModes
        self.position = position
        self.selection = selection.map(DioramaSelection.init)
        self.content = content()
    }

    /// Creates a diorama whose tagged markers select values from your application model.
    ///
    /// Use `.tag(place.id)` on content to match a `UUID?`, enum, or other Hashable & Sendable
    /// selection binding. Untagged markers remain selectable by annotation ID for String bindings.
    /// Removing content preserves the binding, so an off-chunk item can remain selected as you pan.
    public init<SelectionValue: Hashable & Sendable>(
        region: DioramaRegion,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<SelectionValue?>,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.region = region
        self.shape = shape
        self.physicalSize = physicalSize
        self.interactionModes = interactionModes
        self.position = position
        self.selection = DioramaSelection(selection)
        self.content = content()
    }

    /// Creates a diorama with an initial region that subsequent view evaluations do not reset.
    public init(
        initialRegion: DioramaRegion,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<DioramaFeature.ID?>? = nil,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.init(region: initialRegion, shape: shape, physicalSize: physicalSize,
                  interactionModes: interactionModes, position: position, selection: selection, content: content)
        _startupRegion = State(initialValue: initialRegion)
    }

    /// Creates a diorama with an initial region and typed marker selection.
    public init<SelectionValue: Hashable & Sendable>(
        initialRegion: DioramaRegion,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<SelectionValue?>,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.init(region: initialRegion, shape: shape, physicalSize: physicalSize,
                  interactionModes: interactionModes, position: position, selection: selection, content: content)
        _startupRegion = State(initialValue: initialRegion)
    }

    /// Creates a diorama controlled by a geographic position binding on every supported platform.
    ///
    /// The binding owns the ground's center and absolute geographic radius. Application requests
    /// rebuild the ground; pan and ground zoom write resolved positions back without reloading.
    /// `position` independently controls the orbit camera and is ignored in a visionOS volume.
    public init(
        groundPosition: Binding<DioramaGroundPosition>,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<DioramaFeature.ID?>? = nil,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.init(region: groundPosition.wrappedValue.region, shape: shape, physicalSize: physicalSize,
                  interactionModes: interactionModes, position: position, selection: selection, content: content)
        self.groundPosition = groundPosition
        _startupRegion = State(initialValue: groundPosition.wrappedValue.region)
    }

    /// Creates a geographically controlled diorama with typed marker selection.
    public init<SelectionValue: Hashable & Sendable>(
        groundPosition: Binding<DioramaGroundPosition>,
        shape: DioramaShape = .circular,
        physicalSize: Float = 0.8,
        interactionModes: DioramaInteractionModes = .all,
        position: Binding<DioramaCameraPosition>? = nil,
        selection: Binding<SelectionValue?>,
        @DioramaContentBuilder content: () -> DioramaContentGroup = { .empty }
    ) {
        self.init(region: groundPosition.wrappedValue.region, shape: shape, physicalSize: physicalSize,
                  interactionModes: interactionModes, position: position, selection: selection, content: content)
        self.groundPosition = groundPosition
        _startupRegion = State(initialValue: groundPosition.wrappedValue.region)
    }

    public var body: some View {
        let inputs = DioramaViewInputs(
            region: startupRegion ?? region,
            shape: shapeOverride ?? shape,
            physicalSize: physicalSizeOverride ?? physicalSize,
            style: style.resolving(loadingPolicy, interactionModes: interactionModes),
            interactionModes: interactionModes,
            position: position,
            selection: selection,
            content: content,
            groundPosition: groundPosition,
            preservesGround: startupRegion != nil || groundPosition != nil
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
    var selection: DioramaSelection?
    var content: DioramaContentGroup
    var groundPosition: Binding<DioramaGroundPosition>? = nil
    var preservesGround = false

    /// The configuration the pipelines consume, assembled from the public vocabulary.
    var configuration: DioramaConfiguration {
        var configuration = DioramaConfiguration(region: region, shape: shape, physicalSize: physicalSize, style: style)
        configuration.usesGeographicAnchor = preservesGround
        return configuration
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
