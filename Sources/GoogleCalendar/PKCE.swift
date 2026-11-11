import CryptoKit
import Foundation

enum PKCE {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomToken(bytes: Int = 32) -> String {
        var g = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }))
    }

    /// S256: BASE64URL(SHA256(ASCII(verifier))) per RFC 7636.
    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
