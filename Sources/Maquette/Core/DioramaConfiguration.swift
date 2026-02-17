import CoreLocation
import Foundation
import SwiftUI

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

/// Shape of the diorama boundary.
public enum DioramaShape: Sendable {
    /// Circular diorama with the configured diameter.
    case circular
    /// Rectangular diorama with explicit width and depth in meters.
    case rectangular(width: Float, depth: Float)
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
    /// Multiplier applied to elevation values. Default `2.0`.
    ///
    /// Typical values: `1.5`–`2.0` for mountainous regions (>500m relief),
    /// `2.0`–`3.0` for moderate terrain, `3.0`–`5.0` for flat areas.
    public var elevationExaggeration: Float
    /// Color used for the pedestal rim.
    public var baseColor: Color

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
        elevationExaggeration: Float = 2.0,
        baseColor: Color = Color(red: 0.1, green: 0.1, blue: 0.3),
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
        self.baseColor = baseColor
        self.cameraElevation = cameraElevation
        self.cameraDistance = cameraDistance
        self.allowsARPlacement = allowsARPlacement
        self.imagerySource = imagerySource
        self.elevationSource = elevationSource
    }
}
