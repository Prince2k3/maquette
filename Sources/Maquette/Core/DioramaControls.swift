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

    var headingDegrees: Int {
        guard let degrees = heading?.degrees, degrees.isFinite else { return 0 }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return Int((normalized < 0 ? normalized + 360 : normalized).rounded()) % 360
    }
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
    @Environment(\.dioramaControls) private var configuration

    func body(content: Content) -> some View {
        content.overlay(alignment: configuration?.alignment ?? .topLeading) {
            if let configuration {
                configuration.content()
                    .environment(\.dioramaControlState, state)
                    .padding(12)
            }
        }
    }
}
