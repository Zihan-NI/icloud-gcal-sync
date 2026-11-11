import Foundation
import SyncCore

/// The "Desktop app" client JSON from Google Cloud Console.
public struct OAuthClient: Equatable {
    public var clientID: String
    public var clientSecret: String
    public var authURI: URL
    public var tokenURI: URL

    public init(clientID: String, clientSecret: String, authURI: URL, tokenURI: URL) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
    }

    public static func load(from url: URL) throws -> OAuthClient {
        guard let data = try? Data(contentsOf: url) else {
            throw GoogleAPIError.unauthorized("OAuth client file not found at \(url.path). Download the \"Desktop app\" client JSON from Google Cloud Console and save it there.")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> OAuthClient {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = root["installed"] as? [String: Any],
              let id = c["client_id"] as? String, let secret = c["client_secret"] as? String
        else {
            throw GoogleAPIError.malformedResponse("OAuth client file must be a \"Desktop app\" client (top-level key \"installed\")")
        }
        let auth = (c["auth_uri"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let token = (c["token_uri"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://oauth2.googleapis.com/token")!
        return OAuthClient(clientID: id, clientSecret: secret, authURI: auth, tokenURI: token)
    }
}

public struct StoredToken: Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiry: Date?
    public var scopes: [String]

    public init(accessToken: String? = nil, refreshToken: String? = nil, expiry: Date? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
        self.scopes = scopes
    }
}

/// Uses google-auth's key names ("token", "refresh_token", "expiry", "scopes") for both reading
/// and writing, so the Python version and this one can share a token.json.
public enum TokenFile {
    public static func read(_ url: URL) throws -> StoredToken? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw GoogleAPIError.malformedResponse("token file is not a JSON object")
        }
        var scopes = obj["scopes"] as? [String] ?? []
        if scopes.isEmpty, let s = obj["scope"] as? String { scopes = s.split(separator: " ").map(String.init) }
        return StoredToken(accessToken: (obj["token"] as? String) ?? (obj["access_token"] as? String),
                           refreshToken: obj["refresh_token"] as? String,
                           expiry: (obj["expiry"] as? String).flatMap(RFC3339.parse),
                           scopes: scopes)
    }

    /// Written to a sibling temp file created 0600 and renamed into place, so the secret is never
    /// readable by others, not even briefly.
    public static func write(_ token: StoredToken, to url: URL) throws {
        var obj: [String: Any] = ["scopes": token.scopes]
        if let t = token.accessToken { obj["token"] = t }
        if let r = token.refreshToken { obj["refresh_token"] = r }
        if let e = token.expiry { obj["expiry"] = RFC3339.format(e, in: TimeZone(identifier: "UTC")!) }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])

        let tmp = url.path + ".tmp.\(getpid())"
        unlink(tmp)  // a stale temp file from a crash could have looser permissions; O_CREAT keeps those
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw GoogleAPIError.transport("cannot write token file: \(String(cString: strerror(errno)))") }
        var failed = false
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { failed = true; break }
                off += n
            }
        }
        if !failed { fsync(fd) }
        close(fd)
        if failed || rename(tmp, url.path) != 0 {
            unlink(tmp)
            throw GoogleAPIError.transport("cannot write token file: \(String(cString: strerror(errno)))")
        }
    }
}
