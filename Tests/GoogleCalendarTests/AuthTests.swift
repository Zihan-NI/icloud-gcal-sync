import XCTest
@testable import GoogleCalendar
import SyncCore

final class AuthTests: XCTestCase {
    func testPKCEVectorFromRFC7636() {
        XCTAssertEqual(PKCE.challenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = PKCE.randomToken()
        XCTAssertEqual(v.count, 43)
        XCTAssertNotEqual(v, PKCE.randomToken())
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testClientFileParsing() throws {
        let c = try OAuthClient.parse(Data(#"{"installed":{"client_id":"a","client_secret":"b","auth_uri":"https://x/auth","token_uri":"https://x/token","redirect_uris":["http://localhost"]}}"#.utf8))
        XCTAssertEqual(c.clientID, "a"); XCTAssertEqual(c.clientSecret, "b")
        XCTAssertEqual(c.tokenURI.absoluteString, "https://x/token")
        XCTAssertThrowsError(try OAuthClient.parse(Data(#"{"web":{"client_id":"a"}}"#.utf8)))
    }

    func testTokenRoundTripAndMode() throws {
        let env = try Env(token: nil)
        let t = StoredToken(accessToken: "a", refreshToken: "r", expiry: date("2026-01-01T00:00:00Z"), scopes: GoogleScopes.all)
        try TokenFile.write(t, to: env.tokenFile)
        XCTAssertEqual(try TokenFile.read(env.tokenFile), t)
        let perms = try FileManager.default.attributesOfItem(atPath: env.tokenFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try TokenFile.write(t, to: env.tokenFile)  // overwrite keeps the mode
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: env.tokenFile.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.dir.path), ["token.json"])
        XCTAssertNil(try TokenFile.read(env.dir.appendingPathComponent("missing.json")))
    }

    func testReadsPythonTokenFormat() throws {
        let env = try Env(token: nil)
        for expiry in ["2026-01-01T00:00:00.000000Z", "2026-01-01T00:00:00"] {
            let json = #"{"token":"ya29","refresh_token":"1//r","token_uri":"https://oauth2.googleapis.com/token","client_id":"c","client_secret":"s","scopes":["https://www.googleapis.com/auth/calendar"],"expiry":"\#(expiry)"}"#
            try Data(json.utf8).write(to: env.tokenFile)
            let t = try XCTUnwrap(TokenFile.read(env.tokenFile))
            XCTAssertEqual(t.accessToken, "ya29"); XCTAssertEqual(t.refreshToken, "1//r")
            XCTAssertEqual(t.expiry, date("2026-01-01T00:00:00Z"))
            XCTAssertEqual(t.scopes, ["https://www.googleapis.com/auth/calendar"])
        }
    }

    func testRefreshWhenNearExpiryAndPersists() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"new","expires_in":3600}"#)])
        let env = try Env(token: StoredToken(accessToken: "old", refreshToken: "ref", expiry: Date().addingTimeInterval(30), scopes: GoogleScopes.all), authTransport: auth)
        XCTAssertEqual(try env.authorizer.accessToken(), "new")
        XCTAssertEqual(try env.authorizer.accessToken(), "new")
        XCTAssertEqual(auth.requests.count, 1)
        let body = String(data: auth.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=refresh_token")); XCTAssertTrue(body.contains("refresh_token=ref"))
        let saved = try XCTUnwrap(TokenFile.read(env.tokenFile))
        XCTAssertEqual(saved.accessToken, "new"); XCTAssertEqual(saved.refreshToken, "ref")
    }

    func testValidTokenIsNotRefreshed() throws {
        let env = try Env()
        XCTAssertEqual(try env.authorizer.accessToken(), "tok1")
        XCTAssertEqual(env.authTransport.requests.count, 0)
    }

    func testInvalidGrantAndMissingRefreshToken() throws {
        let auth = FakeTransport.script([(400, #"{"error":"invalid_grant"}"#)])
        let env = try Env(token: StoredToken(accessToken: nil, refreshToken: "ref", expiry: nil, scopes: []), authTransport: auth)
        XCTAssertThrowsError(try env.authorizer.accessToken()) {
            guard case .unauthorized(let m)? = $0 as? GoogleAPIError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("auth")); XCTAssertTrue(m.contains("7 days"))
        }
        let env2 = try Env(token: StoredToken(accessToken: "x", refreshToken: nil, expiry: Date(), scopes: []))
        XCTAssertThrowsError(try env2.authorizer.accessToken()) {
            guard case .unauthorized? = $0 as? GoogleAPIError else { return XCTFail("\($0)") }
        }
        let env3 = try Env(token: nil)
        XCTAssertThrowsError(try env3.authorizer.accessToken())
    }

    /// Drives the real loopback listener: the injected "browser" simply requests the redirect URL.
    func testInteractiveFlowAgainstLoopback() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"A","refresh_token":"R","expires_in":3600,"scope":"\#(GoogleScopes.all.joined(separator: " "))"}"#)])
        let env = try Env(token: nil, authTransport: auth)
        var captured: URL?
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { url in
            captured = url
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            DispatchQueue.global().async {
                // A favicon-style request first must not end the wait; a wrong state would.
                _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/favicon.ico")!)
                _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=THECODE&state=\(q["state"]!)")!)
            }
        })
        try az.authorizeInteractively(timeout: 20)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: captured!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(q["scope"], GoogleScopes.all.joined(separator: " "))
        XCTAssertEqual(q["code_challenge_method"], "S256"); XCTAssertEqual(q["access_type"], "offline"); XCTAssertEqual(q["prompt"], "consent")
        let body = String(data: auth.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("code=THECODE")); XCTAssertTrue(body.contains("grant_type=authorization_code"))
        let verifier = body.components(separatedBy: "&").first { $0.hasPrefix("code_verifier=") }!.dropFirst("code_verifier=".count)
        XCTAssertEqual(PKCE.challenge(forVerifier: String(verifier)), q["code_challenge"])
        let saved = try XCTUnwrap(TokenFile.read(env.tokenFile))
        XCTAssertEqual(saved.refreshToken, "R"); XCTAssertEqual(saved.scopes, GoogleScopes.all)
    }

    private func params(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    }

    /// A wrong state is ignored (not trusted, not fatal); the real redirect afterwards still completes.
    func testWrongStateIsIgnoredAndNeverExchanged() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"A","refresh_token":"R","expires_in":3600}"#)])
        let env = try Env(token: nil, authTransport: auth)
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { url in
            let q = self.params(url)
            DispatchQueue.global().async {
                _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=EVIL&state=evil")!)
                _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=GOOD&state=\(q["state"]!)")!)
            }
        })
        try az.authorizeInteractively(timeout: 20)
        XCTAssertEqual(auth.requests.count, 1)
        XCTAssertTrue(String(data: auth.requests[0].httpBody!, encoding: .utf8)!.contains("code=GOOD"))
    }

    func testOnlyWrongStateTimesOutWithoutSavingToken() throws {
        let auth = FakeTransport()
        let env = try Env(token: nil, authTransport: auth)
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { url in
            let q = self.params(url)
            DispatchQueue.global().async { _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=C&state=evil")!) }
        })
        XCTAssertThrowsError(try az.authorizeInteractively(timeout: 2))
        XCTAssertEqual(auth.requests.count, 0)
        XCTAssertNil(try TokenFile.read(env.tokenFile))
    }

    func testCancelledSignInEndsPromptlyWithoutSavingToken() throws {
        let auth = FakeTransport()
        let env = try Env(token: nil, authTransport: auth)
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { _ in })
        let started = Date()
        var polls = 0
        XCTAssertThrowsError(try az.authorizeInteractively(timeout: 60, isCancelled: { polls += 1; return polls > 1 })) { error in
            XCTAssertEqual(error as? GoogleAPIError, .unauthorized("sign-in cancelled"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not wait for the timeout")
        XCTAssertEqual(auth.requests.count, 0)
        XCTAssertNil(try TokenFile.read(env.tokenFile))
    }

    func testBrowserOpenFailureDoesNotAbortFlow() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"A","refresh_token":"R","expires_in":3600}"#)])
        let env = try Env(token: nil, authTransport: auth)
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { url in
            let q = self.params(url)
            DispatchQueue.global().async { _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=C&state=\(q["state"]!)")!) }
            throw GoogleAPIError.transport("no browser")
        })
        try az.authorizeInteractively(timeout: 20)
        XCTAssertEqual(try TokenFile.read(env.tokenFile)?.refreshToken, "R")
    }

    func testMissingGrantedScopeIsRejected() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"A","refresh_token":"R","expires_in":3600,"scope":"https://www.googleapis.com/auth/calendar.calendarlist.readonly"}"#)])
        let env = try Env(token: nil, authTransport: auth)
        let az = GoogleAuthorizer(client: Env.client, tokenFile: env.tokenFile, transport: auth, openURL: { url in
            let q = self.params(url)
            DispatchQueue.global().async { _ = try? Data(contentsOf: URL(string: q["redirect_uri"]! + "/?code=C&state=\(q["state"]!)")!) }
        })
        XCTAssertThrowsError(try az.authorizeInteractively(timeout: 20)) {
            guard case .unauthorized(let m)? = $0 as? GoogleAPIError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("calendar.app.created"))
        }
        XCTAssertNil(try TokenFile.read(env.tokenFile))
    }

    /// The daemon caches the token; `auth` run meanwhile in another process must be picked up.
    func testRefreshUsesRefreshTokenReauthorizedOnDisk() throws {
        let auth = FakeTransport.script([(200, #"{"access_token":"new","expires_in":3600}"#)])
        let env = try Env(token: StoredToken(accessToken: "old", refreshToken: "stale", expiry: Date().addingTimeInterval(-10), scopes: GoogleScopes.all), authTransport: auth)
        _ = try? TokenFile.read(env.tokenFile)
        // First call loads the cache from disk, then the file changes underneath us.
        auth.handler = { _ in (200, #"{"access_token":"first","expires_in":1}"#) }
        XCTAssertEqual(try env.authorizer.accessToken(), "first")
        try TokenFile.write(StoredToken(accessToken: "x", refreshToken: "fresh", expiry: Date(), scopes: GoogleScopes.all), to: env.tokenFile)
        auth.handler = { _ in (200, #"{"access_token":"second","expires_in":3600}"#) }
        XCTAssertEqual(try env.authorizer.accessToken(), "second")
        XCTAssertTrue(String(data: auth.requests.last!.httpBody!, encoding: .utf8)!.contains("refresh_token=fresh"))
    }

    func testStaleTempFileDoesNotWeakenMode() throws {
        let env = try Env(token: nil)
        let tmp = env.tokenFile.path + ".tmp.\(getpid())"
        FileManager.default.createFile(atPath: tmp, contents: Data(), attributes: [.posixPermissions: 0o644])
        try TokenFile.write(StoredToken(accessToken: "a", refreshToken: "r", expiry: nil, scopes: []), to: env.tokenFile)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: env.tokenFile.path)[.posixPermissions] as? Int, 0o600)
    }
}
