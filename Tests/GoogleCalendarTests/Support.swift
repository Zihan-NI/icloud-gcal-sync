import Foundation
import XCTest
@testable import GoogleCalendar
import SyncCore

final class FakeTransport: HTTPTransport {
    typealias Handler = (URLRequest) throws -> (Int, String)
    var handler: Handler
    private(set) var requests: [URLRequest] = []
    init(_ handler: @escaping Handler = { _ in (200, "{}") }) { self.handler = handler }

    /// Replies from a fixed script, one entry per call.
    static func script(_ replies: [(Int, String)]) -> FakeTransport {
        var queue = replies
        return FakeTransport { _ in
            guard !queue.isEmpty else { throw GoogleAPIError.transport("script exhausted") }
            return queue.removeFirst()
        }
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    }

    func bodyJSON(_ i: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

struct Env {
    let dir: URL
    let tokenFile: URL
    let authTransport: FakeTransport
    let authorizer: GoogleAuthorizer
    var sleeps = SleepLog()

    static let client = OAuthClient(clientID: "cid", clientSecret: "csecret",
                                    authURI: URL(string: "https://accounts.example/auth")!,
                                    tokenURI: URL(string: "https://oauth.example/token")!)

    init(token: StoredToken? = StoredToken(accessToken: "tok1", refreshToken: "ref",
                                           expiry: Date().addingTimeInterval(3600), scopes: GoogleScopes.all),
         authTransport: FakeTransport = FakeTransport()) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tokenFile = dir.appendingPathComponent("token.json")
        if let token { try TokenFile.write(token, to: tokenFile) }
        self.authTransport = authTransport
        authorizer = GoogleAuthorizer(client: Env.client, tokenFile: tokenFile, transport: authTransport)
    }

    func client(_ t: HTTPTransport, calendar: String = "cal@group.calendar.google.com") -> GoogleCalendarClient {
        let log = sleeps
        return GoogleCalendarClient(calendarID: calendar, authorizer: authorizer, transport: t,
                                    sleep: { log.values.append($0) })
    }

    func directory(_ t: HTTPTransport) -> GoogleCalendarDirectory {
        GoogleCalendarDirectory(authorizer: authorizer, transport: t, sleep: { _ in })
    }
}

final class SleepLog { var values: [TimeInterval] = [] }

func date(_ s: String) -> Date { RFC3339.parse(s)! }
