import Foundation
import SwiftUI

/// A resolved orbit camera: where it stands around the diorama. The parallel of MapKit's
/// `MapCamera`.
public struct DioramaCamera: Sendable, Equatable {
    /// The orbit angle around the diorama's vertical axis.
    public var azimuth: Angle
    /// The tilt above the horizon. Zero looks at the chunk edge-on; 90° looks straight down.
    public var elevation: Angle
    /// Distance from the orbit target, in scene meters.
    public var distance: Float

    /// Creates a camera.
    public init(azimuth: Angle = .zero, elevation: Angle = .degrees(26), distance: Float = 1.2) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.distance = distance
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

    /// The resolved camera, populated once the scene is live. `nil` under ``automatic`` until the
    /// first gesture writes back, and always `nil` on visionOS.
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

/// Wrapper giving the camera-change closure the `Equatable` identity `@Entry` storage wants.
struct DioramaCameraChangeAction: Equatable {
    let id = UUID()
    let action: @MainActor (DioramaCamera) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var dioramaCameraChangeAction: DioramaCameraChangeAction? = nil
}
