import CoreLocation
import Foundation
import SwiftUI
import simd

/// Controls whether terrain elevation is rendered.
public enum ElevationStyle: Sendable {
    /// Realistic elevation from terrain data.
    case realistic
    /// Flat surface with no elevation.
    case flat
}

/// Source for satellite/aerial imagery tiles.
public enum ImagerySource: Sendable {
    /// ESRI World Imagery (free, no API key required).
    case esriSatellite
    /// MapTiler high-resolution satellite (requires API key).
    case mapTilerSatellite(apiKey: String)
    /// OGC 3D Tiles photorealistic mesh (Google or Cesium). Bypasses the terrain mesh pipeline.
    case photorealistic(provider: any Tiles3DProvider)
}

/// Source for elevation/terrain data.
public enum ElevationSource: Sendable {
    /// Mapzen Terrarium tiles from AWS (free, no API key required).
    case mapzen
    /// MapTiler terrain-rgb tiles (requires API key). Higher resolution in many regions.
    case mapTiler(apiKey: String)
}

/// Outline the terrain chunk is cut to.
///
/// Every shape resolves to a `DioramaBoundary`, which the mesh generator clips the terrain against.
public enum DioramaShape: Sendable, Equatable {
    /// Circular chunk filling the configured diameter.
    case circular
    /// Rectangular chunk with explicit width and depth in meters.
    case rectangular(width: Float, depth: Float)
    /// Rectangular chunk with rounded corners, in meters.
    case roundedRectangular(width: Float, depth: Float, cornerRadius: Float)
    /// Regular polygon filling the configured diameter.
    ///
    /// - Parameters:
    ///   - sides: Number of sides. Values below three are clamped to three.
    ///   - rotation: Rotation of the polygon about its center, in radians.
    case polygonal(sides: Int, rotation: Float)
    /// An arbitrary closed outline given as (x, z) points in diorama-space meters, centered on
    /// the origin. Use for real-world outlines such as city limits or a park boundary.
    case custom(points: [SIMD2<Float>])

    /// A hexagonal chunk, flat-topped.
    public static let hexagonal = DioramaShape.polygonal(sides: 6, rotation: 0)
}

/// Configuration for a diorama instance, defining its geographic region, visual style, and presentation parameters.
public struct DioramaConfiguration: Sendable {
    /// Geographic center of the diorama.
    public var center: CLLocationCoordinate2D
    /// Radius in meters around the center to include.
    public var radiusMeters: Double
    /// Elevation rendering style.
    public var elevation: ElevationStyle
    /// Shape of the diorama boundary.
    public var shape: DioramaShape
    /// Physical diameter in meters. On visionOS this maps to real-world size; on iOS/macOS it is a viewport reference.
    public var physicalDiameter: Float
    /// Explicit zoom level for tile fetching. `nil` means auto-calculate from radius.
    public var zoomLevel: Int?
    /// Multiplier applied to elevation values. Default `1.0` (true-to-scale).
    ///
    /// At `1.0`, the terrain relief matches real-world geographic proportions relative
    /// to the diorama diameter. Increase for more dramatic relief: `1.5`–`2.0` for
    /// mountainous regions, `2.0`–`3.0` for moderate terrain, `3.0`–`5.0` for flat areas.
    public var elevationExaggeration: Float
    /// Appearance of the terrain chunk: how much earth sits beneath the surface, how the cut
    /// walls read, and what the chunk rests on.
    public var chunk: TerrainChunkStyle

    // MARK: - Platform-Specific Hints

    /// Initial orbit camera elevation angle in radians (iOS/macOS only; ignored on visionOS).
    public var cameraElevation: Float?
    /// Initial orbit camera distance in meters (iOS/macOS only; ignored on visionOS).
    public var cameraDistance: Float?
    /// When `true`, enables AR table detection for real-world diorama placement on iOS.
    public var allowsARPlacement: Bool

    // MARK: - Data Sources

    /// Source for satellite/aerial imagery. Defaults to ESRI World Imagery (free).
    public var imagerySource: ImagerySource
    /// Source for elevation/terrain data. Defaults to Mapzen Terrarium (free).
    public var elevationSource: ElevationSource

    /// Creates a diorama configuration.
    public init(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        elevation: ElevationStyle = .realistic,
        shape: DioramaShape = .circular,
        physicalDiameter: Float = 0.8,
        zoomLevel: Int? = nil,
        elevationExaggeration: Float = 1.0,
        chunk: TerrainChunkStyle = .standard,
        cameraElevation: Float? = nil,
        cameraDistance: Float? = nil,
        allowsARPlacement: Bool = false,
        imagerySource: ImagerySource = .esriSatellite,
        elevationSource: ElevationSource = .mapzen
    ) {
        self.center = center
        self.radiusMeters = radiusMeters
        self.elevation = elevation
        self.shape = shape
        self.physicalDiameter = physicalDiameter
        self.zoomLevel = zoomLevel
        self.elevationExaggeration = elevationExaggeration
        self.chunk = chunk
        self.cameraElevation = cameraElevation
        self.cameraDistance = cameraDistance
        self.allowsARPlacement = allowsARPlacement
        self.imagerySource = imagerySource
        self.elevationSource = elevationSource
    }
}

public extension DioramaConfiguration {
    /// The horizontal extent the diorama occupies in diorama meters: X width and Z depth.
    ///
    /// Shapes that carry explicit dimensions use them; the rest fill `physicalDiameter`.
    var horizontalExtent: SIMD2<Float> {
        switch shape {
        case .circular, .polygonal:
            return SIMD2(physicalDiameter, physicalDiameter)
        case .rectangular(let width, let depth),
             .roundedRectangular(let width, let depth, _):
            return SIMD2(width, depth)
        case .custom(let points):
            guard var lo = points.first else {
                return SIMD2(physicalDiameter, physicalDiameter)
            }
            var hi = lo
            for point in points.dropFirst() {
                lo = simd_min(lo, point)
                hi = simd_max(hi, point)
            }
            return hi - lo
        }
    }

    /// The outline the terrain chunk is cut to.
    var boundary: DioramaBoundary {
        DioramaBoundary.make(shape: shape, extent: horizontalExtent)
    }

    /// Converts real-world meters into diorama-space meters.
    var geographicScale: Float {
        physicalDiameter / Float(radiusMeters * 2.0)
    }

    /// The elevation multiplier actually applied, accounting for a `.flat` elevation style.
    var effectiveExaggeration: Float {
        elevation == .realistic ? elevationExaggeration : 0
    }
}
