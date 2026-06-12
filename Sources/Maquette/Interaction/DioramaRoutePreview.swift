import CoreLocation
import Foundation
import SwiftUI

/// Visual style configuration for a route preview animation.
public struct RoutePreviewStyle: Sendable {
    /// Color of the highlighted (already-traversed) portion of the route.
    public var highlightColor: Color
    /// Color of the dimmed (not-yet-traversed) portion of the route.
    public var dimmedColor: Color
    /// Color of the animated marker dot.
    public var markerColor: Color
    /// Width of the route ribbon in diorama-space meters.
    public var lineWidth: Float
    /// Radius of the animated marker sphere in diorama-space meters. `nil` means auto-sized.
    public var markerRadius: Float?

    /// Creates a route preview style.
    ///
    /// - Parameters:
    ///   - highlightColor: Color of the traversed route portion. Defaults to `.yellow`.
    ///   - dimmedColor: Color of the remaining route portion. Defaults to translucent orange.
    ///   - markerColor: Color of the marker sphere. Defaults to `.white`.
    ///   - lineWidth: Width in diorama meters. Defaults to `0.003`.
    ///   - markerRadius: Radius of the marker. `nil` for auto-sizing.
    public init(
        highlightColor: Color = .yellow,
        dimmedColor: Color = Color.orange.opacity(0.3),
        markerColor: Color = .white,
        lineWidth: Float = 0.003,
        markerRadius: Float? = nil
    ) {
        self.highlightColor = highlightColor
        self.dimmedColor = dimmedColor
        self.markerColor = markerColor
        self.lineWidth = lineWidth
        self.markerRadius = markerRadius
    }
}

/// A route preview animation placed on the diorama.
///
/// Shows an animated marker moving along a route path, with a progressive highlight
/// effect: the route behind the marker is bright, the route ahead is dimmed.
///
/// Pair with a ``RoutePreviewController`` passed via the `.routePreviewController(_:)` modifier
/// to control playback.
///
/// ```swift
/// @State private var controller = RoutePreviewController()
///
/// DioramaView(configuration: config) {
///     DioramaRoutePreview(
///         coordinates: routeCoordinates,
///         style: RoutePreviewStyle(highlightColor: .yellow)
///     )
/// }
/// .routePreviewController(controller)
/// ```
public struct DioramaRoutePreview: DioramaContent, Sendable {
    /// The geographic coordinates defining the route path.
    public let coordinates: [CLLocationCoordinate2D]
    /// Visual style for the route and marker.
    public let style: RoutePreviewStyle
    /// Unique identifier for this route preview.
    public let id: String

    /// Creates a route preview.
    ///
    /// - Parameters:
    ///   - coordinates: Geographic coordinates defining the route path.
    ///   - style: Visual style configuration. Defaults to standard style.
    ///   - id: Unique identifier. Defaults to `"route-preview"`.
    public init(
        coordinates: [CLLocationCoordinate2D],
        style: RoutePreviewStyle = RoutePreviewStyle(),
        id: String = "route-preview"
    ) {
        self.coordinates = coordinates
        self.style = style
        self.id = id
    }

    public var items: [DioramaContentItem] {
        [.routePreview(self)]
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    /// The route preview controller provided to the diorama view.
    @Entry var routePreviewController: RoutePreviewController? = nil
}

extension View {
    /// Provides a route preview controller to the diorama view.
    ///
    /// The controller manages playback (play/pause/scrub) for any
    /// ``DioramaRoutePreview`` content inside the diorama.
    ///
    /// ```swift
    /// @State private var controller = RoutePreviewController()
    ///
    /// DioramaView(configuration: config) {
    ///     DioramaRoutePreview(coordinates: coords)
    /// }
    /// .routePreviewController(controller)
    /// ```
    ///
    /// - Parameter controller: The controller to use for route preview playback.
    public func routePreviewController(_ controller: RoutePreviewController) -> some View {
        environment(\.routePreviewController, controller)
    }
}
