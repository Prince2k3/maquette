import Foundation
import os

/// Provides Google Photorealistic 3D Tiles.
///
/// Requires a Google Maps Platform API key with Map Tiles API enabled.
/// Free tier includes ~$200/month credit.
///
/// Usage:
/// ```swift
/// let provider = GoogleTiles3DProvider(apiKey: "your-google-key")
/// ```
public final class GoogleTiles3DProvider: Tiles3DProvider, Sendable {
    private let apiKey: String
    private let httpClient: any HTTPClient
    private let logger = Logger(subsystem: "com.maquette", category: "GoogleTiles3DProvider")
    private let sessionState = SessionState()

    /// Thread-safe session token storage.
    private final class SessionState: @unchecked Sendable {
        private let lock = NSLock()
        private var _token: String?
        private var _baseURL: String?

        var token: String? {
            lock.lock()
            defer { lock.unlock() }
            return _token
        }

        var baseURL: String? {
            lock.lock()
            defer { lock.unlock() }
            return _baseURL
        }

        func set(token: String?, baseURL: String?) {
            lock.lock()
            defer { lock.unlock() }
            _token = token
            _baseURL = baseURL
        }
    }

    /// Creates a Google 3D Tiles provider.
    /// - Parameters:
    ///   - apiKey: Google Maps Platform API key.
    ///   - httpClient: HTTP client for network requests. Defaults to `URLSession.shared`.
    public init(apiKey: String, httpClient: any HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    public func fetchTileset() async throws -> TilesetJSON {
        let urlString = "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid root tileset URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw DioramaError.authenticationFailed(provider: "Google")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Google", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        // Extract session token from response JSON if present
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionToken = json["session"] as? String {
            sessionState.set(token: sessionToken, baseURL: urlString)
            logger.debug("Google session token acquired")
        }

        let tileset: TilesetJSON
        do {
            tileset = try JSONDecoder().decode(TilesetJSON.self, from: data)
        } catch {
            throw DioramaError.tilesetParsingFailed(reason: error.localizedDescription)
        }

        return tileset
    }

    public func fetchTileContent(uri: String) async throws -> Data {
        // Resolve URI relative to root
        var resolvedURL: String
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            resolvedURL = uri
        } else {
            resolvedURL = "https://tile.googleapis.com/v1/3dtiles/\(uri)"
        }

        // Append API key
        if resolvedURL.contains("?") {
            resolvedURL += "&key=\(apiKey)"
        } else {
            resolvedURL += "?key=\(apiKey)"
        }

        // Append session token if available
        if let token = sessionState.token {
            resolvedURL += "&session=\(token)"
        }

        guard let url = URL(string: resolvedURL) else {
            throw DioramaError.glbParsingFailed(reason: "Invalid tile content URL: \(resolvedURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            // Could be expired session token
            if sessionState.token != nil {
                sessionState.set(token: nil, baseURL: nil)
                throw DioramaError.sessionExpired
            }
            throw DioramaError.authenticationFailed(provider: "Google")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Google", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(underlying: URLError(.badServerResponse))
        }
    }

    public var attribution: String { "Google" }
}
