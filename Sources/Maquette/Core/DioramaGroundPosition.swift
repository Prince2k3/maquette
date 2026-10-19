import SwiftUI

/// A geographic request and read-back for the ground beneath a diorama's fixed outline.
///
/// The radius is measured in geographic meters. It changes the ground shown by the chunk;
/// ``DioramaCameraPosition`` independently controls where an orbit camera stands around it.
public struct DioramaGroundPosition: Sendable, Equatable {
    /// The geographic center and nominal radius of the ground currently shown or requested.
    public var region: DioramaRegion

    /// Whether this value was written by an interaction rather than an application request.
    public private(set) var positionedByUser: Bool

    /// Creates an application request for a geographic region.
    ///
    /// An application request specifies an absolute radius. Recenter with the current radius to
    /// preserve the visible ground scale. The orbit camera and physical chunk size stay separate.
    public init(region: DioramaRegion) {
        self.region = region
        positionedByUser = false
    }

    static func resolved(_ region: DioramaRegion, positionedByUser: Bool) -> Self {
        var position = Self(region: region)
        position.positionedByUser = positionedByUser
        return position
    }
}

/// How often a diorama reports navigation changes.
public enum DioramaUpdateFrequency: Sendable {
    /// Reports applied changes while navigation is changing and once when it ends.
    case continuous
    /// Reports once after the interaction, pending pan samples, and globe transition have settled.
    case onEnd
}

/// A resolved geographic navigation update.
public struct DioramaNavigationContext: Sendable, Equatable {
    /// The ground shown beneath the chunk's outline.
    public let position: DioramaGroundPosition
    /// The resolved orbit camera, or `nil` in a visionOS volume.
    public let camera: DioramaCamera?
    /// Whether navigation is changing or has settled.
    public let phase: Phase
    /// What initiated this navigation change.
    public let origin: Origin

    /// The phase of an applied navigation change.
    public enum Phase: Sendable {
        /// Applied navigation is changing.
        case changing
        /// Input, pending pan samples, and transitions have settled.
        case ended
    }
    /// The source of an applied navigation change.
    public enum Origin: Sendable {
        /// An application request or route animation initiated the change.
        case programmatic
        /// A gesture or committed globe return initiated the change.
        case userInteraction
    }
}

extension View {
    /// Observes applied geographic navigation, including pan, ground zoom, and globe returns.
    ///
    /// This callback works on every supported platform. During a globe journey it describes the
    /// chunk's ground; steering is reported when the return commits and the new chunk loads.
    public func onDioramaNavigationChange(
        frequency: DioramaUpdateFrequency = .onEnd,
        _ action: @escaping @MainActor (DioramaNavigationContext) -> Void
    ) -> some View {
        environment(\.dioramaNavigationAction, DioramaNavigationAction(frequency: frequency, action: action))
    }
}

struct DioramaNavigationAction {
    let id = UUID()
    let frequency: DioramaUpdateFrequency
    let action: @MainActor (DioramaNavigationContext) -> Void
}

extension EnvironmentValues {
    @Entry var dioramaNavigationAction: DioramaNavigationAction? = nil
}
