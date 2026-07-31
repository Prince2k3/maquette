import Foundation
import os

/// Fetches building footprints from the OpenStreetMap Overpass API.
///
/// ## Why this is the development path and not the shipping one
///
/// Overpass is a query service for cartographers and analysts, not a tile server for applications:
/// the public instances are slow, aggressively rate-limited, and their usage policy asks that
/// software not point end users at them. It earns its place here for one reason — it answers a
/// bounding-box query with plain JSON, and it needs no key, so buildings can be put on screen
/// against any bounding box at all with nothing to sign up for.
///
/// The shipping route is ``MapTilerBuildingProvider``, which reads the same OSM data pre-baked into
/// vector tiles.
///
/// ## What it does not do
///
/// Only closed ways tagged `building` are read. Multipolygon relations — buildings with courtyards,
/// and a scattering of large complexes — are skipped, as are `building:part` refinements and
/// `min_height`, which together are what separate blocks-on-the-ground from a real 3D city model.
///
/// ## 504 is the normal failure, and it is about the queue rather than the query
///
/// A busy public instance answers **504 Gateway Timeout**: the front-end gives up before the
/// dispatcher has even admitted the query. Measured here against `overpass-api.de`, a downtown San
/// Francisco bbox answered in 2.1 s when it answered at all, and 504'd four times across ten
/// minutes when the instance was loaded — the same query, so nothing about the query was the cause.
/// Retrying the same host inside a few seconds therefore does nothing useful; three things do:
///
/// - **Ask for a smaller slot.** `[timeout:]` is not just an abort deadline, it is what the
///   dispatcher schedules against, so a query declaring 180 s waits for a slot big enough for one.
///   This bbox finishes in about two seconds, so it declares thirty.
/// - **Move to another instance.** The public mirrors are independently loaded, so the fallover is
///   what actually clears a 504. Every default here serves the whole planet — several well-known
///   mirrors carry a regional extract only (`overpass.osm.ch` is Switzerland), and one of those
///   silently returns an empty result set outside its region rather than an error, which would read
///   as a city with no buildings in it.
/// - **Lap them more than once.** They can all be busy at the same moment, so one pass through the
///   list is not enough to call the fetch failed. Measured on device against this preset's bbox:
///   all three 504'd on the first lap, `overpass-api.de` 504'd again on the second, and
///   `overpass.kumi.systems` then answered — 2,368 buildings, 109 s end to end. A single lap would
///   have given up 70 s earlier with nothing.
/// - **Say who is calling.** The usage policy asks for an identifying `User-Agent`, and an
///   unidentified caller is the first one throttled.
public struct OSMBuildingProvider: BuildingProvider {
    private static let logger = Logger(maquette: "OSMBuildingProvider")

    /// Overpass instances to try, in order. Each is tried before any is tried a second time.
    public let endpoints: [URL]
    /// How many times to work through `endpoints` before giving up.
    public let rounds: Int
    /// How many buildings to keep. Beyond this the response is truncated and the drop is logged.
    public let maximumBuildings: Int
    /// Height assumed for a building that declares neither `height` nor `building:levels`.
    public let defaultHeightMeters: Double
    /// Height assumed per storey when only `building:levels` is given.
    public let metersPerLevel: Double

    private let httpClient: any HTTPClient

    /// Full-planet public Overpass instances, most-canonical first.
    public static let defaultEndpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!
    ]

    public init(
        endpoints: [URL] = OSMBuildingProvider.defaultEndpoints,
        rounds: Int = 2,
        maximumBuildings: Int = 12_000,
        defaultHeightMeters: Double = 8,
        metersPerLevel: Double = 3.2,
        httpClient: any HTTPClient = URLSession.shared
    ) {
        self.endpoints = endpoints.isEmpty ? OSMBuildingProvider.defaultEndpoints : endpoints
        self.rounds = max(1, rounds)
        self.maximumBuildings = maximumBuildings
        self.defaultHeightMeters = defaultHeightMeters
        self.metersPerLevel = metersPerLevel
        self.httpClient = httpClient
    }

    /// The statuses worth trying another instance for. Everything else — 400 for a malformed query
    /// above all — would fail identically everywhere, so it is raised on the first answer.
    private static let overloadedStatuses: Set<Int> = [429, 502, 503, 504]

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
        // instead of returning node references that would need a second query to resolve. Thirty
        // seconds is a deadline this query does not need and a slot size the dispatcher can find.
        let query = """
            [out:json][timeout:30];
            way["building"](\(south),\(west),\(north),\(east));
            out geom;
            """

        var lastStatus = 0
        for round in 0..<rounds {
            for endpoint in endpoints {
                switch try await ask(query, of: endpoint) {
                case .answered(let data):
                    return decode(data)
                case .overloaded(let code):
                    lastStatus = code
                    Self.logger.info(
                        "\(endpoint.host() ?? "Overpass") returned \(code); trying another instance"
                    )
                }
            }
            // The instances are independently loaded, so the fallover is what clears a 504 — this
            // pause is only so a second lap does not read as hammering all of them at once.
            if round + 1 < rounds { try await Task.sleep(for: .seconds(2))  }
        }

        throw DioramaError.networkFailure(
            message: "every Overpass instance was busy (last returned \(lastStatus))"
        )
    }

    /// One instance's answer to one query.
    private enum Answer {
        case answered(Data)
        /// The instance is loaded rather than the query being wrong: worth asking another one.
        case overloaded(Int)
    }

    private func ask(_ query: String, of endpoint: URL) async throws -> Answer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(query.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // The usage policy asks callers to identify themselves, and an anonymous one is throttled
        // first.
        request.setValue(MaquetteHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .answered(data) }
        if (200..<300).contains(http.statusCode) { return .answered(data) }
        if Self.overloadedStatuses.contains(http.statusCode) {
            return .overloaded(http.statusCode)
        }
        throw DioramaError.networkFailure(message: "Overpass returned \(http.statusCode)")
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
