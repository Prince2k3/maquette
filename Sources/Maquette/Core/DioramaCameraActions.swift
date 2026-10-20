import Foundation
import Observation
import SwiftUI

/// Constraints shared by camera gestures, bindings, fitting, and imperative actions.
public struct DioramaCameraLimits: Sendable, Equatable {
    /// Whether a geographic focus must lie within the chunk's cut outline.
    public enum FocusPolicy: Sendable, Equatable {
        case insideChunk
        case unrestricted
    }

    /// Allowed distance from the focus in scene meters.
    public let distance: ClosedRange<Float>
    /// Allowed angle from overhead in degrees.
    public let pitchDegrees: ClosedRange<Double>
    public let focusPolicy: FocusPolicy

    /// Rejects nonfinite, nonpositive distance and pitch outside 0 through 90 degrees.
    public init?(distance: ClosedRange<Float> = 0.3...10,
                 pitchDegrees: ClosedRange<Double> = 0...85,
                 focusPolicy: FocusPolicy = .insideChunk) {
        guard distance.lowerBound.isFinite, distance.upperBound.isFinite,
              distance.lowerBound > 0, distance.lowerBound <= distance.upperBound,
              pitchDegrees.lowerBound.isFinite, pitchDegrees.upperBound.isFinite,
              pitchDegrees.lowerBound >= 0, pitchDegrees.upperBound <= 90,
              pitchDegrees.lowerBound <= pitchDegrees.upperBound else { return nil }
        self.distance = distance
        self.pitchDegrees = pitchDegrees
        self.focusPolicy = focusPolicy
    }

    /// Default scene-meter and oblique-view limits.
    public static let `default` = DioramaCameraLimits()!
}

/// How a camera request reaches its resolved pose. Reduce Motion may make a timed move immediate.
public enum DioramaCameraTransition: Sendable, Equatable {
    case immediate
    case easeInOut(duration: TimeInterval)

    var isValid: Bool {
        switch self {
        case .immediate: true
        case .easeInOut(let duration): duration.isFinite && duration >= 0
        }
    }
}

/// What a camera fit should enclose, without relocating the geographic ground.
public enum DioramaCameraFitTarget: Sendable, Equatable {
    case chunk
    case bounds(GeographicBounds)
    /// Explicit string IDs supplied with geographic content's `.id` modifier.
    case contentIDs([String])
}

/// Virtual-camera operations supported by the current presentation and camera owner.
public struct DioramaCameraCapabilities: Sendable, Equatable {
    public let canOrbit: Bool
    public let canFit: Bool
    public static let unavailable = Self(canOrbit: false, canFit: false)
    public static let orbit = Self(canOrbit: true, canFit: true)

    public init(canOrbit: Bool, canFit: Bool) {
        self.canOrbit = canOrbit
        self.canFit = canFit
    }
}

/// Identity of one accepted action. Equal commands always receive different identities.
public struct DioramaCameraRequestID: Sendable, Hashable {
    let rawValue = UUID()
}

/// A synchronous receipt or a terminal outcome of a previously accepted action.
public enum DioramaCameraActionResult: Sendable, Equatable {
    /// Accepted for execution; animation and rendering may still be pending.
    case accepted(DioramaCameraRequestID)
    case unavailable
    case invalidRequest
    /// The actual final frame, after applying camera constraints.
    case completed(DioramaCameraRequestID, DioramaCamera)
    case cancelled(DioramaCameraRequestID)
    /// The requested geography is outside the loaded ground; navigate the ground explicitly.
    case requiresGroundNavigation(DioramaCameraRequestID)
    /// The target cannot fit within the supplied camera limits or viewport padding.
    case constrainedFit(DioramaCameraRequestID)
    /// The requested IDs or focus cannot be resolved in the current scene.
    case invalidTarget(DioramaCameraRequestID)

    var requestID: DioramaCameraRequestID? {
        switch self {
        case .accepted(let id), .cancelled(let id), .requiresGroundNavigation(let id),
             .constrainedFit(let id), .invalidTarget(let id), .completed(let id, _): id
        case .unavailable, .invalidRequest: nil
        }
    }
}

enum CameraCommand {
    case camera(DioramaCamera, DioramaCameraTransition)
    case fit(DioramaCameraFitTarget, EdgeInsets, DioramaCameraTransition)
    case reset
}

/// Per-view command boundary. Geometry, constraints, and animation belong to the orbit model.
@MainActor @Observable
final class CameraActionHost {
    var capabilities = DioramaCameraCapabilities.unavailable
    var receive: ((DioramaCameraRequestID, CameraCommand) -> Void)?
    var cancel: ((DioramaCameraRequestID) -> Void)?
    private(set) var activeRequest: DioramaCameraRequestID?
    private(set) var results: [DioramaCameraRequestID: DioramaCameraActionResult] = [:]
    private(set) var lastResult: DioramaCameraActionResult?
    private var ownerID: ObjectIdentifier?
    private var requestOrder: [DioramaCameraRequestID] = []

    /// A reader owns one host; a second diorama must retain its own independent host.
    func claim(_ owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        guard ownerID == nil || ownerID == id else { return false }
        ownerID = id
        return true
    }

    func release(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner) else { return }
        let previous = activeRequest
        let previousCancellation = cancel
        // Detach before invoking application/model code: cancellation may submit another action
        // or attach a new owner, and teardown must not overwrite that newer lifecycle.
        activeRequest = nil
        receive = nil
        cancel = nil
        capabilities = .unavailable
        ownerID = nil
        if let previous {
            record(.cancelled(previous), for: previous)
            previousCancellation?(previous)
        }
    }

    func submit(_ command: CameraCommand) -> DioramaCameraActionResult {
        guard receive != nil, supports(command) else { return .unavailable }
        let previous = activeRequest
        let previousCancellation = cancel
        let id = DioramaCameraRequestID()
        // Publish this revision before the old owner's cancellation callback. A nested submit
        // is then newer than this action and can supersede it with an explicit terminal result.
        activeRequest = id
        if let previous { record(.cancelled(previous), for: previous) }
        requestOrder.append(id)
        // Keep observations bounded when controls are used throughout a long session.
        if requestOrder.count > 128 { results.removeValue(forKey: requestOrder.removeFirst()) }
        record(.accepted(id), for: id)
        if let previous { previousCancellation?(previous) }
        guard activeRequest == id else { return .accepted(id) }
        // Read the live handler after cancellation; release may have detached the old owner.
        guard let receive, supports(command) else {
            cancelRequest(id)
            return .accepted(id)
        }
        receive(id, command)
        return .accepted(id)
    }

    private func supports(_ command: CameraCommand) -> Bool {
        switch command {
        case .fit: capabilities.canFit
        case .camera: capabilities.canOrbit
        case .reset: capabilities.canOrbit || capabilities.canFit
        }
    }

    func cancelActive() {
        guard let id = activeRequest else { return }
        cancelRequest(id)
    }

    /// Cancels only this revision; delayed cancellation cannot interrupt a newer action.
    func cancelRequest(_ id: DioramaCameraRequestID) {
        guard activeRequest == id else { return }
        activeRequest = nil
        record(.cancelled(id), for: id)
        cancel?(id)
    }

    /// Late completion and cancellation callbacks cannot finish a newer request.
    func complete(_ id: DioramaCameraRequestID, result: DioramaCameraActionResult) {
        guard activeRequest == id, result.requestID == id else { return }
        if case .accepted = result { return }
        activeRequest = nil
        record(result, for: id)
    }

    func complete(_ id: DioramaCameraRequestID, camera: DioramaCamera) {
        complete(id, result: .completed(id, camera))
    }

    private func record(_ result: DioramaCameraActionResult, for id: DioramaCameraRequestID) {
        results[id] = result
        lastResult = result
    }
}

/// Actions scoped to the hosting diorama. Read with `@Environment(\.dioramaCamera)` inside controls.
@MainActor
public struct DioramaCameraProxy {
    let host: CameraActionHost
    public var capabilities: DioramaCameraCapabilities { host.capabilities }
    public var activeRequest: DioramaCameraRequestID? { host.activeRequest }
    public var lastResult: DioramaCameraActionResult? { host.lastResult }

    /// The current receipt or terminal outcome; the latest 128 accepted requests are retained.
    public func result(for id: DioramaCameraRequestID) -> DioramaCameraActionResult? { host.results[id] }

    @discardableResult
    public func fit(_ target: DioramaCameraFitTarget, padding: EdgeInsets = .init(),
                    transition: DioramaCameraTransition = .immediate) -> DioramaCameraActionResult {
        guard transition.isValid,
              [padding.top, padding.leading, padding.bottom, padding.trailing].allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return .invalidRequest }
        switch target {
        case .chunk: break
        case .contentIDs(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { return .invalidRequest }
        case .bounds(let bounds):
            guard validCameraCoordinate(Coordinate(latitude: bounds.south, longitude: bounds.west, altitude: bounds.minimumAltitude)),
                  validCameraCoordinate(Coordinate(latitude: bounds.north, longitude: bounds.east, altitude: bounds.maximumAltitude)),
                  bounds.south <= bounds.north else { return .invalidRequest }
            if let low = bounds.minimumAltitude, let high = bounds.maximumAltitude, low > high { return .invalidRequest }
        }
        return host.submit(.fit(target, padding, transition))
    }

    @discardableResult
    public func setCamera(_ camera: DioramaCamera,
                          transition: DioramaCameraTransition = .immediate) -> DioramaCameraActionResult {
        guard transition.isValid, camera.isValid else { return .invalidRequest }
        return host.submit(.camera(camera, transition))
    }

    @discardableResult
    public func reset() -> DioramaCameraActionResult { host.submit(.reset) }

    /// Cancels the active action at its current pose. Already completed actions remain completed.
    public func cancel() { host.cancelActive() }
}

extension DioramaCamera {
    var isValid: Bool {
        guard heading.radians.isFinite, pitch.radians.isFinite, (0...90).contains(pitch.degrees),
              distance.isFinite, distance > 0 else { return false }
        if case .coordinate(let coordinate, _) = focus { return validCameraCoordinate(coordinate) }
        return true
    }
}

private func validCameraCoordinate(_ coordinate: Coordinate) -> Bool {
    coordinate.latitude.isFinite && (-90...90).contains(coordinate.latitude)
        && coordinate.longitude.isFinite && (-180...180).contains(coordinate.longitude)
        && (coordinate.altitude?.isFinite ?? true)
}

extension EnvironmentValues {
    /// The nearest host's virtual-camera proxy, available within its controls hierarchy.
    @Entry public var dioramaCamera: DioramaCameraProxy? = nil
    @Entry var dioramaCameraActionHost: CameraActionHost? = nil
    @Entry var dioramaCameraLimits: DioramaCameraLimits = .default
    @Entry var dioramaCameraTransition: DioramaCameraTransition = .immediate
    @Entry var dioramaCameraFitInsets: EdgeInsets = .init()
}

extension View {
    /// Applies camera constraints to each diorama in this hierarchy.
    public func dioramaCameraLimits(_ limits: DioramaCameraLimits) -> some View {
        environment(\.dioramaCameraLimits, limits)
    }

    /// Sets the default transition for camera binding requests.
    public func dioramaCameraTransition(_ transition: DioramaCameraTransition) -> some View {
        environment(\.dioramaCameraTransition, transition)
    }
}

/// Provides a scoped camera proxy for application controls around a single diorama.
///
/// Place one diorama in each reader. Independent readers maintain independent camera actions;
/// a second diorama in the same reader keeps its own control host and cannot hijack the first.
@MainActor
public struct DioramaReader<Content: View>: View {
    @State private var host = CameraActionHost()
    private let content: @MainActor (DioramaCameraProxy) -> Content

    public init(@ViewBuilder content: @escaping @MainActor (DioramaCameraProxy) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(DioramaCameraProxy(host: host))
            .environment(\.dioramaCameraActionHost, host)
            .environment(\.dioramaCamera, DioramaCameraProxy(host: host))
    }
}


extension View {
    /// Reserves additional screen points for caller-owned overlays when fitting a camera.
    /// Safe-area insets and scoped diorama controls are also included automatically.
    public func dioramaCameraFitInsets(_ insets: EdgeInsets) -> some View {
        environment(\.dioramaCameraFitInsets, insets)
    }
}
