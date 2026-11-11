import Foundation
import SyncCore

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect. Plain BSD sockets: no dependency
/// and we only ever need to read one request line.
final class LoopbackListener {
    private let fd: Int32
    let port: UInt16

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw GoogleAPIError.transport("socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 8) == 0 else {
            let msg = String(cString: strerror(errno)); close(sock)
            throw GoogleAPIError.transport("cannot listen on loopback: \(msg)")
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = UInt16(bigEndian: out.sin_port)
    }

    deinit { close(fd) }

    /// Waits for the redirect carrying `code` (or `error`). Browsers also fetch /favicon.ico or
    /// open speculative connections; those are answered 404 / ignored and the wait continues.
    func waitForCode(expectedState: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw GoogleAPIError.unauthorized("timed out waiting for the browser authorization (5 minutes)") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(remaining, 1) * 1000))
            if r < 0 && errno != EINTR { throw GoogleAPIError.transport("poll: \(String(cString: strerror(errno)))") }
            if r <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            defer { close(c) }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let query = readQuery(c) else { reply(c, status: "404 Not Found", html: "Not found"); continue }
            let params = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard params["code"] != nil || params["error"] != nil else {
                reply(c, status: "404 Not Found", html: "Not found"); continue
            }
            guard params["state"] == expectedState else {
                // Ignore rather than abort: a stale tab or a local prober must not be able to cancel the real flow.
                reply(c, status: "400 Bad Request", html: "State mismatch; this request was ignored.")
                Log.warning("ignored a loopback request whose OAuth state did not match")
                continue
            }
            if let e = params["error"] {
                reply(c, status: "200 OK", html: "Authorization was not granted (\(htmlEscape(e))). You can close this tab.")
                throw GoogleAPIError.unauthorized("authorization denied: \(e)")
            }
            reply(c, status: "200 OK", html: "Authorization complete. You can close this tab and return to the terminal.")
            return params["code"]!
        }
    }

    private func readQuery(_ c: Int32) -> [URLQueryItem]? {
        var buf = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(3)
        while !buf.contains(10), buf.count < 16384, end.timeIntervalSinceNow > 0 {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 500) > 0 else { continue }
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            buf += chunk[0..<n]
        }
        guard let nl = buf.firstIndex(of: 10),
              let line = String(bytes: buf[0..<nl], encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems ?? []
    }

    private func reply(_ c: Int32, status: String, html: String) {
        let body = "<!doctype html><meta charset=utf-8><title>icloud-gcal-sync</title><body style=\"font-family:system-ui;margin:3em\"><p>\(html)</p>"
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        Array(resp.utf8).withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(c, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
