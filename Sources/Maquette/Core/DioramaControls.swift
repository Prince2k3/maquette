import SwiftUI

/// Returns the hosting diorama to its last application-requested place and orbit.
///
/// Place this button inside ``SwiftUICore/View/dioramaControls(alignment:content:)``. It affects
/// only that diorama, retains appearance and selection, and is disabled without an available host.
/// In a visionOS volume it resets the ground and chunk orientation without moving the volume.
public struct DioramaResetButton: View {
    @Environment(\.dioramaControlState) private var state

    /// Creates a reset button for the hosting diorama.
    public init() {}

    public var body: some View {
        Button("Reset diorama", systemImage: "arrow.counterclockwise") {
            state?.reset()
        }
        .disabled(state?.canReset != true)
        .accessibilityIdentifier("diorama-reset")
    }
}

/// Shows the hosting orbit camera's heading and turns it to face north when activated.
///
/// Tilt and distance are preserved. This control is hidden in visionOS volumes, AR, globe
/// presentation, and route-follow mode, where an orbit heading does not describe the active view.
/// Place it inside ``SwiftUICore/View/dioramaControls(alignment:content:)`` to supply its host.
public struct DioramaCompass: View {
    @Environment(\.dioramaControlState) private var state

    /// Creates a compass for the hosting diorama's orbit camera.
    public init() {}

    public var body: some View {
        if let state, let heading = state.heading {
            Button {
                state.faceNorth()
            } label: {
                Label {
                    Text("Face north")
                } icon: {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.radians(-heading.radians))
                }
            }
            .disabled(!state.canFaceNorth)
            .accessibilityValue(Text("\(state.headingDegrees) degrees"))
            .accessibilityIdentifier("diorama-compass")
        }
    }
}

/// Zooms the hosting diorama's ground or orbit camera by one step at a time.
///
/// Each direction disables independently at its limit. Ground zoom changes the amount of
/// geography inside the chunk; camera zoom changes viewing distance.
public struct DioramaZoomControls: View {
    @Environment(\.dioramaControlState) private var state
    private let target: DioramaZoomTarget

    /// Creates zoom controls. Ground zoom is the default.
    public init(target: DioramaZoomTarget = .ground) { self.target = target }

    public var body: some View {
        let navigation = state?.navigation ?? .unavailable
        HStack {
            Button(target == .ground ? "Zoom ground out" : "Zoom camera out", systemImage: "minus") {
                navigation.zoom(target, -1)
            }
            .disabled(target == .ground ? !navigation.canGroundZoomOut : !navigation.canCameraZoomOut)
            .accessibilityValue(zoomValue(navigation))
            .accessibilityIdentifier(target == .ground ? "diorama-ground-zoom-out" : "diorama-camera-zoom-out")
            Button(target == .ground ? "Zoom ground in" : "Zoom camera in", systemImage: "plus") {
                navigation.zoom(target, 1)
            }
            .disabled(target == .ground ? !navigation.canGroundZoomIn : !navigation.canCameraZoomIn)
            .accessibilityValue(zoomValue(navigation))
            .accessibilityIdentifier(target == .ground ? "diorama-ground-zoom-in" : "diorama-camera-zoom-in")
        }
    }
    private func zoomValue(_ navigation: DioramaControlNavigation) -> Text {
        if target == .ground { Text("Ground scale \(navigation.groundScale, format: .number.precision(.fractionLength(2)))") }
        else { Text("Camera distance \(navigation.cameraDistance, format: .number.precision(.fractionLength(2)))") }
    }

}

/// Adjusts the hosting orbit camera's pitch in degrees with a native slider.
/// Hidden when the presentation has no orbit camera.
public struct DioramaPitchControl: View {
    @Environment(\.dioramaControlState) private var state

    public init() {}

    public var body: some View {
        if let navigation = state?.navigation, let pitch = navigation.pitch {
            Slider(value: Binding(
                get: { pitch.degrees },
                set: { navigation.setPitch($0) }
            ), in: navigation.pitchRange) {
                Text("Camera pitch")
            }
            .disabled(!navigation.canPitch)
            .accessibilityValue(Text("\(Int(pitch.degrees.rounded())) degrees"))
            .accessibilityIdentifier("diorama-pitch")
        }
    }
}

/// Switches the hosting orbit camera between overhead and oblique views.
/// Hidden when the presentation has no orbit camera.
public struct DioramaPerspectiveToggle: View {
    @Environment(\.dioramaControlState) private var state

    public init() {}

    public var body: some View {
        if let navigation = state?.navigation, let pitch = navigation.pitch {
            Button(pitch.degrees < 1 ? "Show oblique view" : "Show overhead view",
                   systemImage: pitch.degrees < 1 ? "cube" : "square") {
                navigation.togglePerspective()
            }
            .disabled(!navigation.canTogglePerspective)
            .accessibilityIdentifier("diorama-perspective")
        }
    }
}

/// Frames the chunk or selected content with the hosting diorama's orbit camera.
public struct DioramaFitButton: View {
    @Environment(\.dioramaControlState) private var state
    @Environment(\.dioramaCamera) private var camera
    private let target: DioramaCameraFitTarget
    private let padding: EdgeInsets

    /// Creates a fit button, optionally reserving additional viewport padding.
    public init(target: DioramaCameraFitTarget = .chunk, padding: EdgeInsets = .init()) {
        self.target = target
        self.padding = padding
    }

    public var body: some View {
        Button("Fit diorama", systemImage: "arrow.up.left.and.arrow.down.right") {
            camera?.fit(target, padding: padding, transition: .easeInOut(duration: 0.35))
        }
        .disabled(state?.navigation.canFit != true || camera == nil)
        .accessibilityIdentifier("diorama-fit")
    }
}

extension View {
    /// Places controls over each diorama in this hierarchy with its own local target.
    ///
    /// ```swift
    /// DioramaView(initialRegion: region)
    ///     .dioramaControls {
    ///         VStack {
    ///             DioramaCompass()
    ///             DioramaResetButton()
    ///         }
    ///         .buttonStyle(.bordered)
    ///     }
    /// ```
    /// The default corner keeps controls separate from attribution and streaming UI. Controls
    /// declared outside this builder have no target. The nearest modifier supplies the builder.
    public func dioramaControls<Controls: View>(
        alignment: Alignment = .topLeading,
        @ViewBuilder content: @escaping @MainActor () -> Controls
    ) -> some View {
        environment(\.dioramaControls, DioramaControlsConfiguration(
            alignment: alignment, content: { AnyView(content()) }
        ))
    }
}

/// A snapshot of capabilities and actions for one diorama. Never shared through a global registry.
struct DioramaControlState {
    let canReset: Bool
    let heading: Angle?
    let canFaceNorth: Bool
    let reset: @MainActor () -> Void
    let faceNorth: @MainActor () -> Void
    var navigation: DioramaControlNavigation = .unavailable

    var headingDegrees: Int {
        guard let degrees = heading?.degrees, degrees.isFinite else { return 0 }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return Int((normalized < 0 ? normalized + 360 : normalized).rounded()) % 360
    }
}

/// Navigation capabilities and actions sampled from one host.
struct DioramaControlNavigation: Sendable {
    let canGroundZoomIn: Bool
    let canGroundZoomOut: Bool
    let canCameraZoomIn: Bool
    let canCameraZoomOut: Bool
    let groundScale: Float
    let cameraDistance: Float
    let pitch: Angle?
    let pitchRange: ClosedRange<Double>
    let canPitch: Bool
    let canFit: Bool
    let canTogglePerspective: Bool
    let zoom: @MainActor (DioramaZoomTarget, Double) -> Void
    let setPitch: @MainActor (Double) -> Void
    let togglePerspective: @MainActor () -> Void

    static let unavailable = Self(
        canGroundZoomIn: false, canGroundZoomOut: false,
        canCameraZoomIn: false, canCameraZoomOut: false,
        groundScale: 1, cameraDistance: 0, pitch: nil, pitchRange: 0...80,
        canPitch: false, canFit: false, canTogglePerspective: false,
        zoom: { _, _ in }, setPitch: { _ in }, togglePerspective: {}
    )
}

struct DioramaControlsConfiguration {
    let alignment: Alignment
    let content: @MainActor () -> AnyView
}

extension EnvironmentValues {
    @Entry var dioramaControls: DioramaControlsConfiguration? = nil
    @Entry var dioramaControlState: DioramaControlState? = nil
}

/// Injects the host only into its controls; sibling dioramas and surrounding app views cannot
/// accidentally inherit its actions.
struct DioramaControlsOverlay: ViewModifier {
    let state: DioramaControlState
    var cameraProxy: DioramaCameraProxy? = nil
    var onInsetsChange: (@MainActor (EdgeInsets) -> Void)? = nil
    @Environment(\.dioramaControls) private var configuration
    @State private var measuredSize = CGSize.zero

    func body(content: Content) -> some View {
        content.overlay(alignment: configuration?.alignment ?? .topLeading) {
            if let configuration {
                configuration.content()
                    .environment(\.dioramaControlState, state)
                    .environment(\.dioramaCamera, cameraProxy)
                    .padding(12)
                    .onGeometryChange(for: CGSize.self) { geometry in
                        geometry.size
                    } action: { size in
                        measuredSize = size
                        reportInsets(size)
                    }
            }
        }
        .onChange(of: configuration?.alignment) { _, _ in reportInsets(measuredSize) }
        .onChange(of: configuration == nil) { _, isAbsent in
            if isAbsent { onInsetsChange?(.init()) }
        }
    }

    private func reportInsets(_ size: CGSize) {
        onInsetsChange?(DioramaControlsLayout.insets(size: size, alignment: configuration?.alignment ?? .topLeading))
    }
}

enum DioramaControlsLayout {
    static func insets(size: CGSize, alignment: Alignment) -> EdgeInsets {
        var insets = EdgeInsets()
        if size.width > size.height * 2 {
            if alignment.vertical == .bottom { insets.bottom = size.height }
            else { insets.top = size.height }
        } else {
            if alignment.horizontal == .trailing { insets.trailing = size.width }
            else { insets.leading = size.width }
        }
        return insets
    }
}
