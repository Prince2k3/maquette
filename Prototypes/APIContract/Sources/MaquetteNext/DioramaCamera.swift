import Foundation
import Maquette
import SwiftUI

public enum DioramaCameraFocus: Sendable, Equatable {
    case chunkCenter
    case coordinate(Coordinate, altitude: AltitudeReference)
}

public struct DioramaCamera: Sendable, Equatable {
    /// Clockwise from geographic north along the viewing direction.
    public var heading: Angle
    /// Degrees from straight down; 0 is overhead and 90 is horizontal.
    public var pitch: Angle
    /// Scene meters, independent of the geographic ground radius.
    public var distance: Float
    public var focus: DioramaCameraFocus
    public init(heading: Angle = .zero, pitch: Angle = .degrees(64), distance: Float = 1.2,
                focus: DioramaCameraFocus = .chunkCenter) {
        self.heading = heading; self.pitch = pitch; self.distance = distance; self.focus = focus
    }

    /// The existing orbit azimuth points from target to camera, opposite the viewing bearing.
    public init(legacy camera: Maquette.DioramaCamera) {
        self.init(heading: .radians(-camera.azimuth.radians),
                  pitch: .degrees(90 - camera.elevation.degrees), distance: camera.distance)
    }
}

public struct DioramaCameraPosition: Sendable, Equatable {
    public let camera: DioramaCamera?
    public static let automatic = Self(camera: nil)
    public static func camera(_ camera: DioramaCamera) -> Self { Self(camera: camera) }
}

public struct DioramaCameraLimits: Sendable, Equatable {
    public let distance: ClosedRange<Float>
    public let pitchDegrees: ClosedRange<Double>
    /// Invalid ranges fail instead of introducing NaNs into camera transforms.
    public init?(distance: ClosedRange<Float>, pitchDegrees: ClosedRange<Double> = 0...85) {
        guard distance.lowerBound.isFinite, distance.upperBound.isFinite, distance.lowerBound > 0,
              pitchDegrees.lowerBound.isFinite, pitchDegrees.upperBound.isFinite,
              pitchDegrees.lowerBound >= 0, pitchDegrees.upperBound <= 90 else { return nil }
        self.distance = distance; self.pitchDegrees = pitchDegrees
    }
}

public enum DioramaCameraTransition: Sendable, Equatable {
    case immediate
    case easeInOut(duration: TimeInterval)
}

public enum DioramaCameraFitTarget: Sendable, Equatable {
    case chunk
    case bounds(GeographicBounds)
    /// Explicit string IDs attached with content .id; typed collection identity stays internal.
    case contentIDs([String])
}

public struct DioramaCameraCapabilities: Sendable, Equatable {
    public let canOrbit: Bool
    public let canFit: Bool
    public static let unavailable = Self(canOrbit: false, canFit: false)
    public static let orbit = Self(canOrbit: true, canFit: true)
}

/// Receipt of an accepted command, not a claim that rendering or animation has completed.
public struct DioramaCameraRequestID: Sendable, Hashable { let rawValue = UUID() }
public enum DioramaCameraActionResult: Sendable, Equatable {
    case accepted(DioramaCameraRequestID)
    case unavailable
    case invalidRequest
}

enum CameraCommand {
    case camera(DioramaCamera, DioramaCameraTransition)
    case fit(DioramaCameraFitTarget, EdgeInsets, DioramaCameraTransition)
    case reset
}

/// Host-owned command boundary; it never uses a global active-diorama registry.
@MainActor @Observable
final class CameraActionHost {
    var capabilities = DioramaCameraCapabilities.unavailable
    var receive: ((DioramaCameraRequestID, CameraCommand) -> Void)?
    var cancel: ((DioramaCameraRequestID) -> Void)?
    private(set) var activeRequest: DioramaCameraRequestID?

    func submit(_ command: CameraCommand) -> DioramaCameraActionResult {
        guard let receive else { return .unavailable }
        switch command {
        case .fit:
            guard capabilities.canFit else { return .unavailable }
        case .camera:
            guard capabilities.canOrbit else { return .unavailable }
        case .reset:
            guard capabilities.canOrbit || capabilities.canFit else { return .unavailable }
        }
        cancelActive()
        let id = DioramaCameraRequestID()
        activeRequest = id
        receive(id, command)
        return .accepted(id)
    }
    func cancelActive() {
        guard let activeRequest else { return }
        self.activeRequest = nil
        cancel?(activeRequest)
    }
    /// Revision check: a late completion cannot finish a newer command.
    func complete(_ id: DioramaCameraRequestID) {
        guard activeRequest == id else { return }
        activeRequest = nil
    }
}

@MainActor
public struct DioramaCameraProxy {
    let host: CameraActionHost
    public var capabilities: DioramaCameraCapabilities { host.capabilities }

    @discardableResult public func fit(_ target: DioramaCameraFitTarget, padding: EdgeInsets = .init(),
                                      transition: DioramaCameraTransition = .immediate) -> DioramaCameraActionResult {
        guard valid(transition), [padding.top, padding.leading, padding.bottom, padding.trailing].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return .invalidRequest
        }
        if case .contentIDs(let ids) = target, ids.isEmpty { return .invalidRequest }
        return host.submit(.fit(target, padding, transition))
    }
    @discardableResult public func setCamera(_ camera: DioramaCamera,
                                            transition: DioramaCameraTransition = .immediate) -> DioramaCameraActionResult {
        guard valid(transition), camera.heading.radians.isFinite, camera.pitch.radians.isFinite,
              (0...90).contains(camera.pitch.degrees), camera.distance.isFinite, camera.distance > 0 else {
            return .invalidRequest
        }
        return host.submit(.camera(camera, transition))
    }
    @discardableResult public func reset() -> DioramaCameraActionResult { host.submit(.reset) }
    public func cancel() { host.cancelActive() }
    private func valid(_ transition: DioramaCameraTransition) -> Bool {
        switch transition {
        case .immediate: true
        case .easeInOut(let duration): duration.isFinite && duration >= 0
        }
    }
}
