import Foundation
import os

/// A building footprint as OpenStreetMap describes it: a closed ring of coordinates and a height.
public struct BuildingFootprint: Sendable, Equatable {
    /// The outline, in geographic coordinates, wound in whatever order OSM stored it.
    public let outline: [Coordinate]
    /// Height above the ground in real meters.
    public let heightMeters: Double

    public init(outline: [Coordinate], heightMeters: Double) {
        self.outline = outline
        self.heightMeters = heightMeters
    }
}

/// Fetches building footprints from the OpenStreetMap Overpass API.
///
/// ## Why this is a prototype and not the shipping path
///
/// Overpass is a query service for cartographers and analysts, not a tile server for applications:
/// the public instances are slow, aggressively rate-limited, and their usage policy asks that
/// software not point end users at them. It earns its place here for one reason — it answers a
/// bounding-box query with plain JSON, so building footprints can be put on screen without first
/// writing a Mapbox Vector Tile reader.
///
/// The shipping route is vector tiles: MapTiler's `openmaptiles` schema carries a `building` layer
/// with `render_height` already normalized, and this package already talks to MapTiler for imagery
/// and terrain, so it would reuse the same key, the same `HTTPClient`, and the same tile cache. What
/// it needs that this does not is a protobuf reader.
///
/// ## What it does not do
///
/// Only closed ways tagged `building` are read. Multipolygon relations — buildings with courtyards,
/// and a scattering of large complexes — are skipped, as are `building:part` refinements and
/// `min_height`, which together are what separate blocks-on-the-ground from a real 3D city model.
public struct OSMBuildingProvider: Sendable {
    private static let logger = Logger(subsystem: "com.maquette", category: "OSMBuildings")

    /// Overpass instance to query.
    public let endpoint: URL
    /// How many buildings to keep. Beyond this the response is truncated and the drop is logged.
    public let maximumBuildings: Int
    /// Height assumed for a building that declares neither `height` nor `building:levels`.
    public let defaultHeightMeters: Double
    /// Height assumed per storey when only `building:levels` is given.
    public let metersPerLevel: Double

    private let httpClient: any HTTPClient

    public init(
        endpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!,
        maximumBuildings: Int = 12_000,
        defaultHeightMeters: Double = 8,
        metersPerLevel: Double = 3.2,
        httpClient: any HTTPClient = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.maximumBuildings = maximumBuildings
        self.defaultHeightMeters = defaultHeightMeters
        self.metersPerLevel = metersPerLevel
        self.httpClient = httpClient
    }

    /// Fetches every building footprint whose way falls inside the bounding box.
    ///
    /// - Parameters:
    ///   - south: Southern latitude bound.
    ///   - west: Western longitude bound.
    ///   - north: Northern latitude bound.
    ///   - east: Eastern longitude bound.
    public func fetchBuildings(
        south: Double,
        west: Double,
        north: Double,
        east: Double
    ) async throws -> [BuildingFootprint] {
        // `out geom` is what makes one request enough: it inlines each way's node coordinates
        // instead of returning node references that would need a second query to resolve.
        let query = """
            [out:json][timeout:60];
            way["building"](\(south),\(west),\(north),\(east));
            out geom;
            """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(query.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await httpClient.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 429 and 504 are the two Overpass answers worth recognizing on sight: the public
            // instances rate-limit hard, and a busy one times the query out rather than queueing it.
            throw DioramaError.networkFailure(
                message: "Overpass returned \(http.statusCode)"
            )
        }

        return decode(data)
    }

    /// Turns an Overpass JSON response into footprints. Separated from the fetch so it can be
    /// tested against a recorded payload without a network.
    func decode(_ data: Data) -> [BuildingFootprint] {
        let response: OverpassResponse
        do {
            response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch {
            Self.logger.error("Could not decode the Overpass response: \(error.localizedDescription)")
            return []
        }

        var buildings: [BuildingFootprint] = []
        buildings.reserveCapacity(min(response.elements.count, maximumBuildings))
        var skipped = 0

        for element in response.elements {
            guard let geometry = element.geometry else { continue }

            // Overpass repeats the first node as the last to close the ring. Triangulation and
            // extrusion both treat the outline as implicitly closed, so a duplicated point would
            // put a zero-length wall in the mesh.
            var outline = geometry.map { Coordinate(latitude: $0.lat, longitude: $0.lon) }
            if let first = outline.first, let last = outline.last,
               first.latitude == last.latitude, first.longitude == last.longitude {
                outline.removeLast()
            }
            guard outline.count >= 3 else {
                skipped += 1
                continue
            }

            guard buildings.count < maximumBuildings else {
                skipped += 1
                continue
            }

            buildings.append(
                BuildingFootprint(
                    outline: outline,
                    heightMeters: height(from: element.tags)
                )
            )
        }

        if skipped > 0 {
            Self.logger.info(
                """
                Kept \(buildings.count) building footprints and dropped \(skipped) \
                (degenerate outlines, or past the \(self.maximumBuildings) cap)
                """
            )
        }
        return buildings
    }

    /// Resolves a building's height from its tags, in real meters.
    ///
    /// `height` wins, then `building:levels` times a storey, then a default. OSM's `height` is
    /// documented as meters and usually is a bare number, but a unit suffix is common enough to be
    /// worth handling, and feet appear often enough in North American data to be worth converting
    /// rather than silently reading as meters — a 40-foot building recorded as 40 meters is a
    /// skyscraper on a residential street.
    func height(from tags: [String: String]?) -> Double {
        guard let tags else { return defaultHeightMeters }

        if let raw = tags["height"], let parsed = Self.parseLength(raw) {
            return parsed
        }
        if let levels = tags["building:levels"], let count = Double(
            levels.trimmingCharacters(in: .whitespaces)
        ), count > 0 {
            return count * metersPerLevel
        }
        return defaultHeightMeters
    }

    /// Parses an OSM length, honouring the unit suffixes the schema allows.
    static func parseLength(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        // Feet-and-inches, e.g. `40'6"`. The inches are noise at diorama scale but the feet are not.
        if let apostrophe = text.firstIndex(of: "'") {
            guard let feet = Double(text[text.startIndex..<apostrophe]) else { return nil }
            return feet * 0.3048
        }
        if text.hasSuffix("ft") {
            guard let feet = Double(text.dropLast(2).trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return feet * 0.3048
        }
        if text.hasSuffix("m") {
            guard let meters = Double(text.dropLast().trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return meters
        }
        return Double(text)
    }
}

// MARK: - Overpass JSON

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let geometry: [Point]?
        let tags: [String: String]?
    }

    struct Point: Decodable {
        let lat: Double
        let lon: Double
    }
}
