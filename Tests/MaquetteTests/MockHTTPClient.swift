import Foundation
@testable import Maquette

/// Mock HTTP client for testing providers without real network calls.
struct MockHTTPClient: HTTPClient, Sendable {
    /// Mapping from URL string to response data and status code.
    let responses: [String: MockResponse]

    struct MockResponse: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        init(data: Data = Data(), statusCode: Int = 200, headers: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
        }
    }

    init(responses: [String: MockResponse] = [:]) {
        self.responses = responses
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        return try respond(for: url)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        return try respond(for: url)
    }

    private func respond(for url: URL) throws -> (Data, URLResponse) {
        let urlString = url.absoluteString
        if let mock = responses[urlString] {
            let response = HTTPURLResponse(
                url: url,
                statusCode: mock.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: mock.headers
            )!
            return (mock.data, response)
        }

        // Check for prefix matches (useful for tile URLs with varying coordinates)
        for (key, mock) in responses {
            if urlString.hasPrefix(key) || urlString.contains(key) {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: mock.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: mock.headers
                )!
                return (mock.data, response)
            }
        }

        // Default: 404
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }
}
