import Foundation
import simd

/// The sphere the diorama zooms out to, and the mapping between its surface and the world.
///
/// ## Why the rows step in Mercator, not in latitude
///
/// The globe wears the same Web Mercator raster tiles the chunk does, composited into one world
/// image by ``DioramaMaterials/compositeSatelliteImage(tiles:minX:minY:tilesWide:tilesTall:)``.
/// Mercator's rows are not evenly spaced in latitude — that is the entire point of the projection —
/// so a sphere whose rows stepped evenly in latitude would need the image reprojected before it
/// could wear it. Stepping evenly in Mercator y instead makes V linear in the image's own rows, so
/// the texture goes on unmodified and the mapping is exact rather than resampled.
///
/// The conversion is ``TileMath`` at zoom 0, where the whole world is one tile and a tile point is
/// therefore already the unit square. Routing through it rather than restating the formula is
/// deliberate: the globe and the chunk then cannot disagree about where a coordinate is, which is
/// the same discipline ``DioramaProjection`` exists to enforce.
///
/// ## The poles
///
/// Mercator runs to ±85.0511°, so no tile covers the last five degrees at either end. The mesh
/// closes them with a ring of pole vertices carrying the *edge row's* V, which smears the topmost
/// and bottommost pixel rows radially into each cap — ice at one end, Antarctica at the other, which
/// is close enough to what is actually there. A single pole vertex would be cheaper and wrong: one
/// vertex can hold only one U, so the texture would pinch into it from every direction at once.
///
/// ## The frame
///
/// +Y is the north pole, and a coordinate's position is `(cos·sin lon, sin lat, cos·cos lon)` — so
/// the prime meridian faces +Z and 90°E faces +X. That is the same convention ``CameraController``
/// already orbits in, which makes its azimuth a longitude and its elevation a latitude directly.
enum GlobeGeometry {
    /// The latitude Web Mercator stops at, in degrees. Everything beyond is cap.
    public static let mercatorLimitDegrees: Double = 85.05112877980659

    /// Mesh buffers in the layout `MeshDescriptor` consumes.
    public struct Surface {
        public var positions: [SIMD3<Float>] = []
        public var normals: [SIMD3<Float>] = []
        public var uvs: [SIMD2<Float>] = []
        public var indices: [UInt32] = []
    }

    // MARK: - The Mapping

    /// The point on a globe of the given radius that a coordinate sits at.
    ///
    /// Altitude is ignored: the globe is a sphere, not a terrain model, and the scale it is seen at
    /// makes the world's relief thinner than the mesh.
    public static func position(for coordinate: Coordinate, radius: Float) -> SIMD3<Float> {
        direction(for: coordinate) * radius
    }

    /// The outward unit normal at a coordinate — the globe's position divided by its radius.
    public static func direction(for coordinate: Coordinate) -> SIMD3<Float> {
        let lat = coordinate.latitudeRadians
        let lon = coordinate.longitudeRadians
        let cosLat = cos(lat)
        return SIMD3(Float(cosLat * sin(lon)), Float(sin(lat)), Float(cosLat * cos(lon)))
    }

    /// The coordinate a direction from the globe's centre points at.
    ///
    /// The direction need not be normalized. A zero vector has no coordinate and returns `nil`
    /// rather than a plausible one at the origin.
    public static func coordinate(forDirection direction: SIMD3<Float>) -> Coordinate? {
        let length = simd_length(direction)
        guard length > 0 else { return nil }
        let unit = SIMD3<Double>(direction) / Double(length)
        return Coordinate(
            latitude: asin(min(max(unit.y, -1), 1)) * 180 / .pi,
            longitude: atan2(unit.x, unit.z) * 180 / .pi
        )
    }

    /// Where a coordinate lands on the composited world image.
    ///
    /// V is flipped because the mosaic is drawn north-up while RealityKit counts texture rows from
    /// the bottom — the same trap ``TerrainHeightField/textureCoordinate(atX:z:)`` and `GLBParser`
    /// both document, and it hides the same way here: a mirrored globe is still a globe until you
    /// look for a continent you know the shape of.
    public static func textureCoordinate(for coordinate: Coordinate) -> SIMD2<Float> {
        let tile = TileMath.tilePoint(for: coordinate, zoom: 0)
        return SIMD2(Float(tile.x), Float(1 - tile.y))
    }

    // MARK: - Mesh

    /// Builds the globe's surface. Exposed without RealityKit so it can be tested anywhere.
    ///
    /// - Parameters:
    ///   - radius: Sphere radius in diorama meters.
    ///   - rows: Latitude bands across the Mercator range. Bands crowd towards the poles, which is
    ///     where the projection stretches, so the equator is the coarsest part of the sphere and the
    ///     one to size this against.
    ///   - columns: Longitude divisions. The seam column is duplicated so the texture does not run
    ///     backwards across the antimeridian, which is why a row holds `columns + 1` vertices.
    public static func build(radius: Float, rows: Int = 128, columns: Int = 256) -> Surface {
        var surface = Surface()
        let rows = max(2, rows)
        let columns = max(3, columns)

        // Two extra rings beyond the Mercator band, one per pole cap.
        let ringCount = rows + 3
        let perRing = columns + 1
        surface.positions.reserveCapacity(ringCount * perRing)
        surface.normals.reserveCapacity(ringCount * perRing)
        surface.uvs.reserveCapacity(ringCount * perRing)
        surface.indices.reserveCapacity((ringCount - 1) * columns * 6)

        // Ring 0 is the north pole cap, rings 1...rows+1 span Mercator from north to south, and the
        // last ring is the south pole cap. A cap ring shares its neighbour's V so the smear into it
        // is seamless, and sits at the axis so it closes the sphere exactly.
        for ring in 0..<ringCount {
            let isNorthCap = ring == 0
            let isSouthCap = ring == ringCount - 1
            let band = min(max(ring - 1, 0), rows)
            let mercatorY = Double(band) / Double(rows)

            for column in 0..<perRing {
                let u = Double(column) / Double(columns)
                let coordinate = TileMath.coordinate(forTilePoint: SIMD2(u, mercatorY), zoom: 0)

                let direction: SIMD3<Float>
                if isNorthCap {
                    direction = SIMD3(0, 1, 0)
                } else if isSouthCap {
                    direction = SIMD3(0, -1, 0)
                } else {
                    direction = Self.direction(for: coordinate)
                }

                surface.positions.append(direction * radius)
                surface.normals.append(direction)
                // The seam's second copy is at u = 1 exactly; reading the coordinate back would give
                // -180° and put it at u = 0, wrapping the texture the wrong way round the globe.
                surface.uvs.append(SIMD2(Float(u), Float(1 - mercatorY)))
            }
        }

        // Wound so the outward face is the front one: north-west, south-west, south-east.
        for ring in 0..<(ringCount - 1) {
            let top = ring * perRing
            let bottom = (ring + 1) * perRing
            for column in 0..<columns {
                let nw = UInt32(top + column)
                let ne = UInt32(top + column + 1)
                let sw = UInt32(bottom + column)
                let se = UInt32(bottom + column + 1)
                surface.indices.append(contentsOf: [nw, sw, se, nw, se, ne])
            }
        }

        return surface
    }
}
