public import Foundation

/// Why a download failed; every case becomes "unknown" in the update list, never an error dialog.
public enum FetchError: Error, Sendable, Equatable {
    /// Only HTTPS is ever contacted, so a feed cannot be tampered with on the way.
    case insecureURL
    case requestFailed
    case badStatus(Int)
    case tooLarge
}

/// The only way ClenvraKit reaches the network, injected so tests use canned responses and never connect.
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

/// Fetches over HTTPS with an ephemeral session: no cookies, no cache, no credentials, bounded size and time.
public struct URLSessionFetcher: HTTPFetching {
    /// Appcasts and lookup responses are small; anything larger is not what we asked for.
    public static let maximumBytes = 4_000_000

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public func data(from url: URL) async throws -> Data {
        guard Self.isSecure(url) else { throw FetchError.insecureURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SecureRedirects())
        } catch {
            throw FetchError.requestFailed
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.requestFailed }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.badStatus(http.statusCode) }
        guard data.count <= Self.maximumBytes else { throw FetchError.tooLarge }
        return data
    }

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host() ?? "").isEmpty
    }
}

/// Refuses redirects that leave HTTPS, so an HTTPS feed cannot be downgraded to plain HTTP.
private final class SecureRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, URLSessionFetcher.isSecure(url) else { return nil }
        return request
    }
}
