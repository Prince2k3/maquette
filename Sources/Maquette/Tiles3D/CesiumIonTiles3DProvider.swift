import Foundation
import os

/// Provides 3D Tiles from Cesium ion.
///
/// Requires a Cesium ion access token. Free tier available at https://ion.cesium.com
///
/// Usage:
/// ```swift
/// let provider = CesiumIonTiles3DProvider(
///     accessToken: "your-cesium-token",
///     assetId: 2275207  // Cesium OSM Buildings
/// )
/// ```
public final class CesiumIonTiles3DProvider: Tiles3DProvider, Sendable {
    private let accessToken: String
    private let assetId: Int
    private let httpClient: any HTTPClient
    private let logger = Logger(subsystem: "com.maquette", category: "CesiumIonTiles3DProvider")
    private let endpointState = EndpointState()

    /// Thread-safe endpoint token storage.
    private final class EndpointState: @unchecked Sendable {
        private let lock = NSLock()
        private var _endpointURL: String?
        private var _endpointToken: String?

        var endpointURL: String? {
            lock.lock()
            defer { lock.unlock() }
            return _endpointURL
        }

        var endpointToken: String? {
            lock.lock()
            defer { lock.unlock() }
            return _endpointToken
        }

        func set(url: String?, token: String?) {
            lock.lock()
            defer { lock.unlock() }
            _endpointURL = url
            _endpointToken = token
        }
    }

    /// Cesium ion endpoint response.
    private struct EndpointResponse: Codable {
        let url: String
        let accessToken: String
        let type: String?
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

    public func fetchTileset() async throws -> TilesetJSON {
        // Step 1: Get endpoint
        let endpointURLString = "https://api.cesium.com/v1/assets/\(assetId)/endpoint?access_token=\(accessToken)"
        guard let endpointURL = URL(string: endpointURLString) else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid Cesium endpoint URL")
        }

        let (endpointData, endpointResponse) = try await httpClient.data(from: endpointURL)

        guard let httpResponse = endpointResponse as? HTTPURLResponse else {
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
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
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        let endpoint: EndpointResponse
        do {
            endpoint = try JSONDecoder().decode(EndpointResponse.self, from: endpointData)
        } catch {
            throw DioramaError.tilesetParsingFailed(reason: "Failed to decode Cesium endpoint: \(error)")
        }

        endpointState.set(url: endpoint.url, token: endpoint.accessToken)
        logger.debug("Cesium endpoint acquired: \(endpoint.url)")

        // Step 2: Fetch tileset.json using the endpoint token
        let tilesetURLString = "\(endpoint.url)/tileset.json"
        guard let tilesetURL = URL(string: tilesetURLString) else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid tileset URL from Cesium endpoint")
        }

        var request = URLRequest(url: tilesetURL)
        request.setValue("Bearer \(endpoint.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (tilesetData, tilesetResponse) = try await httpClient.data(for: request)

        guard let tilesetHTTPResponse = tilesetResponse as? HTTPURLResponse,
              (200...299).contains(tilesetHTTPResponse.statusCode) else {
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        let tileset: TilesetJSON
        do {
            tileset = try JSONDecoder().decode(TilesetJSON.self, from: tilesetData)
        } catch {
            throw DioramaError.tilesetParsingFailed(reason: error.localizedDescription)
        }

        return tileset
    }

    public func fetchTileContent(uri: String) async throws -> Data {
        guard let baseURL = endpointState.endpointURL,
              let token = endpointState.endpointToken else {
            throw DioramaError.sessionExpired
        }

        // Resolve URI relative to endpoint base URL
        let resolvedURL: String
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            resolvedURL = uri
        } else {
            resolvedURL = "\(baseURL)/\(uri)"
        }

        guard let url = URL(string: resolvedURL) else {
            throw DioramaError.glbParsingFailed(reason: "Invalid tile content URL: \(resolvedURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            endpointState.set(url: nil, token: nil)
            throw DioramaError.sessionExpired
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Cesium", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }
    }

    public var attribution: String { "Cesium" }
}
