import Foundation
import SwiftUI

/// The geographic point the orbit camera looks at.
public enum DioramaCameraFocus: Sendable, Equatable {
    /// The center of the current chunk.
    case chunkCenter
    /// A geographic location resolved through the active terrain projection.
    case coordinate(Coordinate, altitude: AltitudeReference)
}

/// A resolved orbit camera, independent of the geographic ground region.
public struct DioramaCamera: Sendable, Equatable {
    /// Clockwise from geographic north along the viewing direction.
    public var heading: Angle
    /// Angle from straight down: zero is overhead and 90 degrees is horizontal.
    public var pitch: Angle
    /// Distance from the focus in scene meters.
    public var distance: Float
    /// The target, reprojected when the ground changes.
    public var focus: DioramaCameraFocus

    /// Creates an orbit camera. Invalid values are rejected when requested by the host.
    public init(heading: Angle = .zero, pitch: Angle = .degrees(64), distance: Float = 1.2,
                focus: DioramaCameraFocus = .chunkCenter) {
        self.heading = heading
        self.pitch = pitch
        self.distance = distance
        self.focus = focus
    }
}

/// A camera *request*, plus read-back of where the user left it. The parallel of MapKit's
/// `MapCameraPosition`.
///
/// Hand a binding of one to ``DioramaView``: setting it to ``camera(_:)`` moves the camera, and
/// user gestures write back the resolved position with ``positionedByUser`` true — so an app can
/// both drive the camera and follow it.
///
/// visionOS has no virtual camera — the user physically moves around the volume — so there the
/// binding is accepted but never written, ``camera`` stays `nil`, and requests are no-ops.
public struct DioramaCameraPosition: Sendable, Equatable {
    enum Request: Sendable, Equatable {
        /// The framework frames the loaded chunk itself.
        case automatic
        /// An explicit orbit position.
        case camera(DioramaCamera)
    }

    var request: Request

    /// Whether the value was last written by user interaction rather than by the app.
    public private(set) var positionedByUser: Bool

    /// The framework frames the loaded chunk itself.
    public static let automatic = DioramaCameraPosition(request: .automatic, positionedByUser: false)

    /// An explicit orbit position.
    public static func camera(_ camera: DioramaCamera) -> DioramaCameraPosition {
        DioramaCameraPosition(request: .camera(camera), positionedByUser: false)
    }

    /// The requested or resolved camera. Automatic framing writes a resolved value when loaded.
    /// A visionOS volume leaves application values untouched and does not resolve a virtual camera.
    public var camera: DioramaCamera? {
        if case .camera(let camera) = request { return camera }
        return nil
    }

    /// A position written back by a gesture. Internal — this is the only way `positionedByUser`
    /// becomes true, so the flag means what it says.
    static func userPositioned(_ camera: DioramaCamera) -> DioramaCameraPosition {
        DioramaCameraPosition(request: .camera(camera), positionedByUser: true)
    }
}

extension View {
    /// Observes resolved orbit movement continuously or after input and transitions settle.
    /// This overload reports a context; the original overload continues to receive a camera.
    /// A visionOS volume has no orbit camera and does not call either overload.
    public func onDioramaCameraChange(
        frequency: DioramaUpdateFrequency,
        _ action: @escaping @MainActor (DioramaCameraChangeContext) -> Void
    ) -> some View {
        environment(\.dioramaCameraObservation, DioramaCameraObservationAction(frequency: frequency, action: action))
    }

    /// Performs an action when a diorama in this hierarchy moves its orbit camera.
    ///
    /// Fires on user gestures and on programmatic moves alike, at the gesture's own cadence.
    /// iOS and macOS only; a visionOS diorama has no camera and never calls it.
    public func onDioramaCameraChange(
        _ action: @escaping @MainActor (DioramaCamera) -> Void
    ) -> some View {
        environment(\.dioramaCameraChangeAction, DioramaCameraChangeAction(action: action))
    }
}

/// A resolved orbit-camera update and the phase and source of its movement.
public struct DioramaCameraChangeContext: Sendable, Equatable {
    /// Actual camera movement lifecycle, including cancellation at the current pose.
    public enum Phase: Sendable {
        case changing
        case ended
        case cancelled
    }

    /// The orbit camera after the change was applied.
    public let camera: DioramaCamera
    /// Whether camera movement is ongoing or has settled.
    public let phase: Phase
    /// What initiated the camera movement.
    public let origin: DioramaNavigationContext.Origin
}

struct DioramaCameraObservationAction {
    let id = UUID()
    let frequency: DioramaUpdateFrequency
    let action: @MainActor (DioramaCameraChangeContext) -> Void
}

extension EnvironmentValues {
    @Entry var dioramaCameraObservation: DioramaCameraObservationAction? = nil
}

/// Wrapper giving the camera-change closure the `Equatable` identity `@Entry` storage wants.
struct DioramaCameraChangeAction: Equatable {
    let id = UUID()
    let action: @MainActor (DioramaCamera) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var dioramaCameraChangeAction: DioramaCameraChangeAction? = nil
}
