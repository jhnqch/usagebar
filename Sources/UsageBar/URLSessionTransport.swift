import Foundation
import UsageCore

/// Key providers' requests: an ephemeral session that keeps nothing on disk
/// (no cache, cookies or credentials) and never follows a redirect, so the
/// `Authorization` header `KeyClient` added can't be carried to another host.
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async -> PollOutcome {
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .networkError }
            let retryAfter = PollSchedule.retryAfter(header: http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            return .response(status: http.statusCode, body: body, retryAfter: retryAfter)
        } catch {
            return .networkError
        }
    }
}

/// A redirect comes back as the answer instead of being followed.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
