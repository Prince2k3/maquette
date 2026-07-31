import Foundation

/// Shared HTTP conventions for every provider in the package.
enum MaquetteHTTP {
    /// The User-Agent every request identifies itself with.
    static let userAgent = "Maquette/1.0"

    /// Builds a request carrying the package's standard headers.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Maps a keyed provider's tile response onto the package's error vocabulary.
    ///
    /// One statement of the status-code policy — success passes the data through, 401/403 is a bad
    /// key, 429 carries the server's `Retry-After` if it sent one, and anything else reads as the
    /// tile not existing — so the providers that share it cannot drift apart in how the same server
    /// behaviour is reported.
    static func validateTileResponse(
        _ response: URLResponse,
        data: Data,
        provider: String,
        x: Int, y: Int, zoom: Int
    ) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }
        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw DioramaError.authenticationFailed(provider: provider)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DioramaError.rateLimited(provider: provider, retryAfter: retryAfter)
        default:
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }
    }
}
