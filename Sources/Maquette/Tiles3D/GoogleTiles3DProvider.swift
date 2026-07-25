import Foundation
import os

/// Provides Google Photorealistic 3D Tiles.
///
/// Requires a Google Maps Platform API key with Map Tiles API enabled.
///
/// ## Cost
///
/// Google bills the **root tileset request** for Photorealistic 3D Tiles; session tokens and the
/// individual tiles are not billed. A diorama therefore costs one event per root request, however
/// much geometry it goes on to stream, and `rootCacheLifetime` is what keeps repeated loads free.
///
/// Usage:
/// ```swift
/// let provider = GoogleTiles3DProvider(apiKey: "your-google-key")
/// ```
public final class GoogleTiles3DProvider: Tiles3DProvider, Sendable {
    /// Base host that content URIs resolve against.
    private static let tileHost = URL(string: "https://tile.googleapis.com/")!

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
    ///   - rootCacheLifetime: How long a fetched root tileset is reused before another is
    ///     requested. The root request is the billable event for Photorealistic 3D Tiles, so this
    ///     is the setting that decides what a diorama costs.
    ///
    ///     It cannot simply be raised, though. The session token lives inside the cached response,
    ///     and once Google expires it every tile request fails with **400** rather than a 401, so
    ///     a too-generous lifetime silently produces an empty model. Measured: a root twenty
    ///     minutes old already returned 400 for tiles while a fresh one returned 200. The default
    ///     is well inside that, which still collapses preset switches, reloads, and quick
    ///     relaunches into a single billable request.
    ///   - rootCache: Where root tilesets are cached. Defaults to a process-wide cache so
    ///     separate views share one billable request.
    public init(
        apiKey: String,
        httpClient: any HTTPClient = URLSession.shared,
        rootCacheLifetime: TimeInterval = 10 * 60,
        rootCache: RootTilesetCache = .shared
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.rootCacheLifetime = rootCacheLifetime
        self.rootCache = rootCache
    }

    private let rootCache: RootTilesetCache

    /// How long a cached root tileset is reused before another is requested.
    private let rootCacheLifetime: TimeInterval

    /// Cache key. Includes the credentials, since a session belongs to the key that created it.
    private var rootCacheKey: String { "google-3dtiles-\(apiKey)" }

    public func fetchTileset() async throws -> TilesetJSON {
        let urlString = "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(apiKey)"

        // Google bills the root tileset request and nothing else — not session tokens, not the
        // individual tiles. Reusing a recent root is therefore the whole of cost control, and the
        // session token embedded in its tile URIs is reused along with it.
        if let cached = await rootCache.cached(
            key: rootCacheKey,
            maximumAge: rootCacheLifetime
        ) {
            if let json = try? JSONSerialization.jsonObject(with: cached) as? [String: Any],
               let sessionToken = json["session"] as? String {
                sessionState.set(token: sessionToken, baseURL: urlString)
            }
            if let tileset = try? JSONDecoder().decode(TilesetJSON.self, from: cached) {
                logger.info("Reused cached root tileset — no billable request")
                return tileset
            }
            // Unreadable cache entry; fall through and fetch a fresh one.
            await rootCache.invalidate(key: rootCacheKey)
        }

        guard let url = URL(string: urlString) else {
            throw DioramaError.tilesetParsingFailed(reason: "Invalid root tileset URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(message: "Invalid response from Google root tileset")
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
            throw DioramaError.networkFailure(message: "Google root tileset returned HTTP \(httpResponse.statusCode)")
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

        await rootCache.store(key: rootCacheKey, data: data)
        logger.info("Fetched a new root tileset — one billable request")

        return tileset
    }

    /// Discards the cached root so the next load establishes a new session.
    ///
    /// Costs a billable request, so it is only worth doing when tile requests start failing
    /// authentication, which is how an expired session presents.
    public func invalidateCachedRoot() async {
        await rootCache.invalidate(key: rootCacheKey)
    }

    public func fetchTileContent(uri: String) async throws -> Data {
        // Google returns content URIs as absolute paths ("/v1/3dtiles/datasets/…") already
        // carrying a session parameter. Joining those onto a base path by hand doubles the path
        // and every tile 404s, so resolve them properly and only add what is missing.
        guard var components = URLComponents(
            url: URL(string: uri, relativeTo: Self.tileHost)?.absoluteURL
                ?? Self.tileHost.appendingPathComponent(uri),
            resolvingAgainstBaseURL: true
        ) else {
            throw DioramaError.glbParsingFailed(reason: "Invalid tile content URL: \(uri)")
        }

        var items = components.queryItems ?? []
        let present = Set(items.map(\.name))
        if !present.contains("key") {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        if !present.contains("session"), let token = sessionState.token {
            items.append(URLQueryItem(name: "session", value: token))
        }
        components.queryItems = items

        let resolvedURL = components.string ?? uri

        guard let url = URL(string: resolvedURL) else {
            throw DioramaError.glbParsingFailed(reason: "Invalid tile content URL: \(resolvedURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Maquette/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.networkFailure(message: "Invalid response fetching Google tile content")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            // Most likely an expired session. The cached root carries that session in its tile
            // URIs, so it has to go too — otherwise the next load reuses the same dead session and
            // every tile keeps failing.
            if sessionState.token != nil {
                sessionState.set(token: nil, baseURL: nil)
                await rootCache.invalidate(key: rootCacheKey)
                throw DioramaError.sessionExpired
            }
            throw DioramaError.authenticationFailed(provider: "Google")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "Google", retryAfter: retryAfter)
        default:
            throw DioramaError.networkFailure(message: "Google tile fetch returned HTTP \(httpResponse.statusCode)")
        }
    }

    public var attribution: String { "Google" }
}
