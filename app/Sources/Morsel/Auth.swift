import CryptoKit
import Foundation
import Supabase

struct AuthenticatedSession: Equatable, Sendable {
    let userID: UUID
    let email: String?

    init(userID: UUID, email: String?) {
        self.userID = userID
        self.email = email
    }

    init(session: Session) {
        userID = session.user.id
        email = session.user.email
    }
}

protocol SupabaseAuthenticating {
    func restoreSession() async throws -> AuthenticatedSession?
    func requestEmailOTP(email: String) async throws
    func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession
    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession
}

struct SupabaseAuthClient: SupabaseAuthenticating {
    let client: SupabaseClient?

    func restoreSession() async throws -> AuthenticatedSession? {
        guard let client else {
            throw MorselError.configurationMissing
        }
        do {
            return AuthenticatedSession(session: try await client.auth.session)
        } catch AuthError.sessionMissing {
            return nil
        }
    }

    func requestEmailOTP(email: String) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            throw MorselError.invalidInput("Enter a valid email address.")
        }
        guard let client else {
            throw MorselError.configurationMissing
        }
        try await client.auth.signInWithOTP(email: normalizedEmail, shouldCreateUser: true)
    }

    func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber) else {
            throw MorselError.invalidInput("Enter the six-digit code from your email.")
        }
        guard let client else {
            throw MorselError.configurationMissing
        }
        let response = try await client.auth.verifyOTP(
            email: normalizedEmail,
            token: normalizedCode,
            type: .email
        )
        guard let session = response.session else {
            throw MorselError.invalidData("Supabase did not return an authenticated session.")
        }
        return AuthenticatedSession(session: session)
    }

    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession {
        guard !identityToken.isEmpty else {
            throw MorselError.invalidInput("Apple sign-in did not return an identity token.")
        }
        guard let client else {
            throw MorselError.configurationMissing
        }
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: identityToken,
                nonce: nonce
            )
        )
        return AuthenticatedSession(session: session)
    }
}

enum AppleNonce {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in
            alphabet[Int.random(in: alphabet.indices, using: &generator)]
        })
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}
