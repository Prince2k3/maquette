import Foundation

/// Abstraction over URL-based HTTP networking for testability.
///
/// `URLSession` conforms to this protocol out of the box. In tests, supply
/// a mock implementation to avoid real network calls.
public protocol HTTPClient: Sendable {
    /// Fetches data from the given URL.
    func data(from url: URL) async throws -> (Data, URLResponse)

    /// Fetches data using the given request.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
