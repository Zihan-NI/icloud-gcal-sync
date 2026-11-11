import Foundation
import SyncCore

public protocol HTTPTransport {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

/// Blocking URLSession wrapper. The engine runs on a serial queue and wants plain throwing calls.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        // Ephemeral: no cookies or disk cache; tokens never end up in URLCache.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // A session is not released until it is invalidated.
    deinit { session.finishTasksAndInvalidate() }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    public func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            sem.signal()
        }.resume()
        sem.wait()
        if let e = box.error { throw GoogleAPIError.transport(e.localizedDescription) }
        guard let http = box.response as? HTTPURLResponse else {
            throw GoogleAPIError.transport("response was not HTTP")
        }
        return (box.data ?? Data(), http)
    }
}

enum Form {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

/// RFC 3339 parsing that tolerates what Google and google-auth actually emit: any number of
/// fractional digits, any offset, and (for token.json) no zone designator at all, meaning UTC.
enum RFC3339 {
    static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard let tIdx = s.firstIndex(where: { $0 == "T" || $0 == "t" }) else { return nil }
        var fraction = 0.0
        if let dot = s.firstIndex(of: "."), dot > tIdx {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + s[dot..<end]) ?? 0
            s.removeSubrange(dot..<end)
        }
        let tail = s[s.index(after: tIdx)...]
        let hasZone = tail.hasSuffix("Z") || tail.hasSuffix("z") || tail.contains("+") || tail.contains("-")
        if !hasZone { s += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { return nil }
        return d.addingTimeInterval(fraction)
    }

    static func format(_ date: Date, in tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = tz
        return f.string(from: date)
    }
}
