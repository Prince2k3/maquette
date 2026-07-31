import Foundation
import os
import Synchronization

/// Provides 3D Tiles from Cesium ion.
///
/// Requires a Cesium ion access token. Free tier available at https://ion.cesium.com
///
/// Usage:
/// ```swift
/// let provider = CesiumIonTiles3DProvider(
///     accessToken: "your-cesium-token",
///     assetId: 2275207  // Google Photorealistic 3D Tiles
/// )
/// ```
public final class CesiumIonTiles3DProvider: Tiles3DProvider, Sendable {
    private let accessToken: String
    private let assetId: Int
    private let httpClient: any HTTPClient
    private let logger = Logger(maquette: "CesiumIonTiles3DProvider")
    private let endpointState = Mutex(EndpointState())

    /// Endpoint token storage, guarded by the `Mutex` above.
    private struct EndpointState: Sendable {
        var tilesetBaseURL: URL?
        /// Query string from the tileset URL (e.g., "key=ABC&session=XYZ").
        var tilesetQuery: String?
        var endpointToken: String?
        var isExternal: Bool = false
    }

    /// Cesium ion endpoint response.
    ///
    /// Regular ion assets return `{ "url": "...", "accessToken": "...", "type": "..." }`.
    /// External assets (e.g., Google Photorealistic 3D Tiles) return
    /// `{ "externalType": "3DTILES", "options": { "url": "..." } }` with no bearer token.
    private struct EndpointResponse: Codable {
        let type: String?
        let url: String?
        let accessToken: String?
        let externalType: String?
        let options: EndpointOptions?

        struct EndpointOptions: Codable {
            let url: String?
        }

        /// Resolved asset URL — checks `options.url` (external) then `url` (regular).
        var resolvedURL: String? {
            options?.url ?? url
        }

        /// Whether this is an external asset (no bearer token needed).
        var isExternal: Bool {
            externalType != nil
        }
    }

    /// Creates a Cesium ion 3D Tiles provider.
    /// - Parameters:
    ///   - accessToken: Long-lived Cesium ion access token.
    ///   - assetId: Asset ID on Cesium ion.
    ///   - httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(accessToken: String, assetId: Int, httpClient: any HTTPClient = URLSession.shared) {
        self.accessToken = accessToken
        self.assetId = assetId
        self.httpClient = httpClient
    }

    public func fetchTileset() async throws -> Data {
        // Step 1: Get endpoint
        let endpointURLString = "https://api.cesium.com/v1/assets/\(assetId)/endpoint?access_token=\(accessToken)"
        guard let endpointURL = URL(string: endpointURLString) else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid Cesium endpoint URL")
        }

        let (endpointData, endpointResponse) = try await httpClient.data(from: endpointURL)

        guard let httpResponse = endpointResponse as? HTTPURLResponse else {
            throw DioramaError.networkFailure(message: "Invalid response from Cesium endpoint")
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw DioramaError.authenticationFailed(provider: "Cesium")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Cesium", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(
                message: "Cesium endpoint returned HTTP \(httpResponse.statusCode)"
            )
        }

        let endpoint: EndpointResponse
        do {
            endpoint = try JSONDecoder().decode(EndpointResponse.self, from: endpointData)
        } catch {
            throw DioramaError.tilesetParsingFailed(reason: "Failed to decode Cesium endpoint: \(error)")
        }

        guard let assetURL = endpoint.resolvedURL else {
            throw DioramaError.tilesetParsingFailed(reason: "Cesium endpoint response missing asset URL")
        }

        logger.debug("Cesium endpoint acquired (external=\(endpoint.isExternal)): \(assetURL)")

        // Step 2: Fetch tileset.json.
        // Some assets return a URL whose path already points to a .json file
        // (possibly with query parameters). Only append /tileset.json when the
        // URL path doesn't already reference a JSON file.
        let tilesetURL: URL
        if let parsed = URL(string: assetURL),
           parsed.path.hasSuffix(".json") {
            tilesetURL = parsed
        } else if let parsed = URL(string: "\(assetURL)/tileset.json") {
            tilesetURL = parsed
        } else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid tileset URL from Cesium endpoint")
        }

        var request = URLRequest(url: tilesetURL)
        // External assets (e.g., Google 3D Tiles) don't use a bearer token.
        if let token = endpoint.accessToken, !endpoint.isExternal {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(MaquetteHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        let (tilesetData, tilesetResponse) = try await httpClient.data(for: request)

        guard let tilesetHTTPResponse = tilesetResponse as? HTTPURLResponse,
              (200...299).contains(tilesetHTTPResponse.statusCode) else {
            let statusCode = (tilesetResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw DioramaError.networkFailure(
                message: "Tileset fetch failed with HTTP \(statusCode) from \(tilesetURL.host ?? "unknown host")"
            )
        }

        // Parsed here only to mine the session token out of the content URIs; the library parses
        // the document again for traversal, which is cheap next to the fetch either side of it.
        let tileset: TilesetJSON
        do {
            tileset = try JSONDecoder().decode(TilesetJSON.self, from: tilesetData)
        } catch {
            throw DioramaError.tilesetParsingFailed(reason: error.localizedDescription)
        }

        // Store tileset base URL (parent directory) and query string for resolving
        // relative tile URIs. The query must be re-appended because URL(string:relativeTo:)
        // drops the base URL's query per RFC 3986 — losing API keys, session tokens, etc.
        //
        // Google 3D Tiles embeds the session token in content URIs within the tileset JSON,
        // not in the tileset URL itself (which only has `key=`). Extract the session from
        // content URIs and merge it into the stored query so all requests include it.
        let tilesetBase = tilesetURL.deletingLastPathComponent()
        var storedQuery = tilesetURL.query ?? ""
        if let sessionValue = Self.extractSessionFromTileset(tileset) {
            if storedQuery.isEmpty {
                storedQuery = "session=\(sessionValue)"
            } else if !storedQuery.contains("session=") {
                storedQuery += "&session=\(sessionValue)"
            }
        }
        endpointState.withLock {
            $0 = EndpointState(
                tilesetBaseURL: tilesetBase,
                tilesetQuery: storedQuery.isEmpty ? nil : storedQuery,
                endpointToken: endpoint.accessToken,
                isExternal: endpoint.isExternal
            )
        }

        return tilesetData
    }

    public func fetchTileContent(uri: String) async throws -> Data {
        let state = endpointState.withLock { $0 }
        guard let baseURL = state.tilesetBaseURL else {
            throw DioramaError.sessionExpired
        }

        let isExternal = state.isExternal
        if !isExternal && state.endpointToken == nil {
            throw DioramaError.sessionExpired
        }

        // Resolve URI relative to the tileset base directory, re-appending the
        // tileset's query parameters (API key, session token, etc.) that standard
        // URL resolution drops per RFC 3986.
        let url: URL
        if uri.hasPrefix("http://") || uri.hasPrefix("https://"),
           let absolute = URL(string: uri) {
            url = absolute
        } else if let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
            // Re-append the tileset's query parameters using URLComponents
            // for robust handling of existing vs missing query strings.
            if let query = state.tilesetQuery,
               var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) {
                let existingItems = components.queryItems ?? []
                // Parse stored query into individual items
                let storedComponents = URLComponents(string: "?\(query)")
                let additionalItems = storedComponents?.queryItems ?? []
                // Deduplicate: only add params not already present
                let existingKeys = Set(existingItems.map(\.name))
                let newItems = additionalItems.filter { !existingKeys.contains($0.name) }
                components.queryItems = existingItems + newItems
                url = components.url ?? resolved
            } else {
                url = resolved
            }
        } else {
            throw DioramaError.networkFailure(message: "Invalid tile content URL")
        }

        logger.debug("Fetching tile: \(url.absoluteString)")

        var request = URLRequest(url: url)
        if let token = state.endpointToken, !isExternal {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(MaquetteHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(message: "Invalid response fetching Cesium tile content")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            endpointState.withLock { $0 = EndpointState() }
            throw DioramaError.sessionExpired
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Cesium", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(
                message: "Cesium tile fetch returned HTTP \(httpResponse.statusCode)"
            )
        }
    }

    public var attribution: String { "Cesium" }

    /// Extracts the `session` query parameter from the first content URI in a tileset.
    ///
    /// Google 3D Tiles embeds the session token in content URIs within the tileset JSON
    /// rather than in the tileset URL itself. This walks the tile tree to find it.
    private static func extractSessionFromTileset(_ tileset: TilesetJSON) -> String? {
        func findSession(in tile: TileJSON) -> String? {
            if let uri = tile.content?.uri,
               let components = URLComponents(string: uri),
               let session = components.queryItems?.first(where: { $0.name == "session" })?.value {
                return session
            }
            for child in tile.children ?? [] {
                if let session = findSession(in: child) { return session }
            }
            return nil
        }
        return findSession(in: tileset.root)
    }
}
