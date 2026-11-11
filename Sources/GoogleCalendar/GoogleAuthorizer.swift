import Foundation
import SyncCore

public enum GoogleScopes {
    public static let calendar = "https://www.googleapis.com/auth/calendar.app.created"
    public static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    public static let all = [calendar, calendarList]
}

public final class GoogleAuthorizer {
    private let client: OAuthClient
    private let tokenFile: URL
    private let transport: HTTPTransport
    private let now: () -> Date
    private let openURL: (URL) throws -> Void
    private var token: StoredToken?
    private var loaded = false

    public static let reauthHint = "run `icloud-gcal-sync auth` to authorize again. If your Google Cloud project is still in \"Testing\" mode, refresh tokens expire after 7 days; publish the OAuth consent screen to \"In production\" to avoid that."

    public init(client: OAuthClient, tokenFile: URL, transport: HTTPTransport,
                now: @escaping () -> Date = Date.init,
                openURL: @escaping (URL) throws -> Void = GoogleAuthorizer.openInBrowser) {
        self.client = client
        self.tokenFile = tokenFile
        self.transport = transport
        self.now = now
        self.openURL = openURL
    }

    public static func openInBrowser(_ url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw GoogleAPIError.transport("open exited with status \(p.terminationStatus)") }
    }

    public func accessToken() throws -> String {
        if !loaded {
            token = try TokenFile.read(tokenFile)
            loaded = true
        }
        guard let t = token else {
            throw GoogleAPIError.unauthorized("no token found at \(tokenFile.path); " + Self.reauthHint)
        }
        if let a = t.accessToken, let exp = t.expiry, exp.timeIntervalSince(now()) > 60 { return a }
        return try refresh(t)
    }

    /// Called after a 401: the cached access token is evidently no good, whatever its expiry says.
    public func invalidateAccessToken() {
        token?.accessToken = nil
    }

    private func refresh(_ old: StoredToken) throws -> String {
        // `auth` may have been run by another process since we cached the token; its refresh token
        // is the newest one, so a daemon recovers from re-authorization without a restart.
        var old = old
        if let disk = (try? TokenFile.read(tokenFile)) ?? nil, let r = disk.refreshToken, !r.isEmpty {
            old.refreshToken = r
        }
        guard let refreshToken = old.refreshToken, !refreshToken.isEmpty else {
            throw GoogleAPIError.unauthorized("the token has no refresh token; " + Self.reauthHint)
        }
        let json = try postToken([("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                                  ("client_id", client.clientID), ("client_secret", client.clientSecret)])
        guard let access = json["access_token"] as? String else {
            throw GoogleAPIError.malformedResponse("token response has no access_token")
        }
        var t = old
        t.accessToken = access
        t.expiry = now().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let r = json["refresh_token"] as? String { t.refreshToken = r }
        token = t
        try TokenFile.write(t, to: tokenFile)
        Log.debug("refreshed Google access token")
        return access
    }

    private func postToken(_ fields: [(String, String)]) throws -> [String: Any] {
        var req = URLRequest(url: client.tokenURI)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Form.encode(fields).utf8)
        let (data, resp) = try transport.send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(resp.statusCode) else {
            if json["error"] as? String == "invalid_grant" {
                throw GoogleAPIError.unauthorized("Google rejected the stored authorization (invalid_grant); " + Self.reauthHint)
            }
            if resp.statusCode >= 500 || resp.statusCode == 429 {
                throw GoogleAPIError.transport("token endpoint HTTP \(resp.statusCode)")
            }
            throw GoogleAPIError.http(status: resp.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }

    /// `isCancelled` is polled about once a second while waiting for the browser.
    public func authorizeInteractively(timeout: TimeInterval = 300, isCancelled: () -> Bool = { false }) throws {
        let listener = try LoopbackListener()
        let redirect = "http://127.0.0.1:\(listener.port)"
        let verifier = PKCE.randomToken()
        let state = PKCE.randomToken(bytes: 16)

        var comps = URLComponents(url: client.authURI, resolvingAgainstBaseURL: false)!
        let query: [(String, String)] = [
            ("client_id", client.clientID), ("redirect_uri", redirect), ("response_type", "code"),
            ("scope", GoogleScopes.all.joined(separator: " ")),
            ("code_challenge", PKCE.challenge(forVerifier: verifier)), ("code_challenge_method", "S256"),
            ("state", state),
            // offline + consent: Google only returns a refresh token on the first consent otherwise.
            ("access_type", "offline"), ("prompt", "consent"),
        ]
        comps.percentEncodedQuery = Form.encode(query)
        let authURL = comps.url!
        Log.info("Opening the browser to authorize Google Calendar access. If it does not open, visit: \(authURL.absoluteString)")
        do { try openURL(authURL) } catch {
            // The URL is logged above, so the user can still open it by hand.
            Log.warning("could not open the browser (\(error)); open the URL above manually")
        }

        let code = try listener.waitForCode(expectedState: state, timeout: timeout, isCancelled: isCancelled)
        let json = try postToken([("grant_type", "authorization_code"), ("code", code),
                                  ("client_id", client.clientID), ("client_secret", client.clientSecret),
                                  ("redirect_uri", redirect), ("code_verifier", verifier)])
        guard let access = json["access_token"] as? String else {
            throw GoogleAPIError.malformedResponse("token response has no access_token")
        }
        guard let refresh = json["refresh_token"] as? String, !refresh.isEmpty else {
            throw GoogleAPIError.unauthorized("Google did not return a refresh token. Remove this app at https://myaccount.google.com/permissions and sign in again.")
        }
        let granted = (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? GoogleScopes.all
        // Granular consent lets the user untick a scope; a token without it fails later with a confusing 403.
        let missing = GoogleScopes.all.filter { !granted.contains($0) }
        guard missing.isEmpty else {
            throw GoogleAPIError.unauthorized("the authorization did not grant: \(missing.joined(separator: ", ")). Sign in again and leave every permission checked.")
        }
        let t = StoredToken(accessToken: access, refreshToken: refresh,
                            expiry: now().addingTimeInterval((json["expires_in"] as? Double) ?? 3600), scopes: granted)
        try TokenFile.write(t, to: tokenFile)
        token = t
        loaded = true
        Log.info("Google authorization saved to \(tokenFile.path)")
    }
}
