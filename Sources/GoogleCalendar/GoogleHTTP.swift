import Foundation
import SyncCore

/// Authenticated request execution shared by the event client and the calendar directory:
/// bearer token, retry with backoff, one token refresh on 401.
final class GoogleHTTP {
    static let base = "https://www.googleapis.com/calendar/v3"
    static let maxAttempts = 5

    private let transport: HTTPTransport
    private let authorizer: GoogleAuthorizer
    private let sleep: (TimeInterval) -> Void

    init(transport: HTTPTransport, authorizer: GoogleAuthorizer, sleep: @escaping (TimeInterval) -> Void) {
        self.transport = transport
        self.authorizer = authorizer
        self.sleep = sleep
    }

    static func pathComponent(_ s: String) -> String { Form.escape(s) }

    /// Returns the body and status for any 2xx or any status in `also`; throws for everything else.
    func request(_ method: String, _ path: String, query: [(String, String)] = [], body: [String: Any]? = nil,
                 also: Set<Int> = []) throws -> (Data, Int) {
        var urlString = Self.base + path
        if !query.isEmpty { urlString += "?" + Form.encode(query) }
        guard let url = URL(string: urlString) else { throw GoogleAPIError.malformedResponse("bad URL \(urlString)") }
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }

        var attempt = 1
        var refreshedAfter401 = false
        while true {
            let failure: GoogleAPIError
            do {
                var req = URLRequest(url: url)
                req.httpMethod = method
                req.setValue("Bearer \(try authorizer.accessToken())", forHTTPHeaderField: "Authorization")
                if let payload {
                    req.httpBody = payload
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let (data, resp) = try transport.send(req)
                let status = resp.statusCode
                if (200..<300).contains(status) || also.contains(status) { return (data, status) }
                let text = String(data: data, encoding: .utf8) ?? ""
                if status == 401 {
                    if refreshedAfter401 {
                        throw GoogleAPIError.unauthorized("Google rejected the access token even after refreshing; " + GoogleAuthorizer.reauthHint)
                    }
                    refreshedAfter401 = true
                    authorizer.invalidateAccessToken()
                    continue
                }
                guard Self.isRetryable(status: status, body: data) else {
                    throw GoogleAPIError.http(status: status, body: text)
                }
                failure = .http(status: status, body: text)
            } catch let e as GoogleAPIError {
                guard case .transport = e else { throw e }
                failure = e
            } catch {
                failure = .transport(error.localizedDescription)
            }
            if attempt >= Self.maxAttempts { throw failure }
            let delay = Double(1 << (attempt - 1)) * Double.random(in: 1...1.25)
            Log.warning("Google API \(method) \(path) failed (\(failure)); retry \(attempt)/\(Self.maxAttempts - 1) in \(Int(delay)) s")
            sleep(delay)
            attempt += 1
        }
    }

    static func isRetryable(status: Int, body: Data) -> Bool {
        if [429, 500, 502, 503, 504].contains(status) { return true }
        guard status == 403,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let errors = err["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ["rateLimitExceeded", "userRateLimitExceeded"].contains($0["reason"] as? String ?? "") }
    }

    func json(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAPIError.malformedResponse("response is not a JSON object")
        }
        return o
    }
}
