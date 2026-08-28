import Foundation

struct AuthenticatedSession: Equatable, Sendable {
    let userID: UUID
    let accessToken: String
    let email: String?
}

protocol SupabaseAuthenticating {
    func requestEmailOTP(email: String) async throws
    func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession
    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession
}

struct SupabaseAuthClient: SupabaseAuthenticating {
    let baseURL: URL?
    let anonKey: String
    let urlSession: URLSession

    init(baseURL: URL?, anonKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
    }

    func requestEmailOTP(email: String) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            throw MorselError.invalidInput("Enter a valid email address.")
        }
        _ = try await perform(
            path: ["auth", "v1", "otp"],
            query: [],
            body: EmailOTPRequest(email: normalizedEmail, createUser: true)
        )
    }

    func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber) else {
            throw MorselError.invalidInput("Enter the six-digit code from your email.")
        }
        let data = try await perform(
            path: ["auth", "v1", "token"],
            query: [URLQueryItem(name: "grant_type", value: "otp")],
            body: EmailTokenRequest(email: normalizedEmail, token: normalizedCode, type: "email")
        )
        return try parseSession(data, fallbackEmail: normalizedEmail)
    }

    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession {
        guard !identityToken.isEmpty else {
            throw MorselError.invalidInput("Apple sign-in did not return an identity token.")
        }
        let data = try await perform(
            path: ["auth", "v1", "token"],
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: AppleTokenRequest(provider: "apple", identityToken: identityToken, nonce: nonce)
        )
        return try parseSession(data, fallbackEmail: nil)
    }

    private func perform<Body: Encodable>(
        path: [String],
        query: [URLQueryItem],
        body: Body
    ) async throws -> Data {
        guard let baseURL, !anonKey.isEmpty else {
            throw MorselError.configurationMissing
        }
        let pathURL = path.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw MorselError.invalidData("The Supabase URL is invalid.")
        }
        components.queryItems = query
        guard let url = components.url else {
            throw MorselError.invalidData("The Supabase auth URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MorselError.invalidData("Supabase returned an invalid response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MorselError.requestFailed(httpResponse.statusCode, message)
        }
        return data
    }

    private func parseSession(_ data: Data, fallbackEmail: String?) throws -> AuthenticatedSession {
        do {
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            guard !response.accessToken.isEmpty,
                  let userID = UUID(uuidString: response.user.id) else {
                throw MorselError.invalidData("Supabase returned an invalid auth session.")
            }
            return AuthenticatedSession(
                userID: userID,
                accessToken: response.accessToken,
                email: response.user.email ?? fallbackEmail
            )
        } catch let error as MorselError {
            throw error
        } catch {
            throw MorselError.decodingFailed
        }
    }
}

private struct EmailOTPRequest: Encodable {
    let email: String
    let createUser: Bool

    enum CodingKeys: String, CodingKey {
        case email
        case createUser = "create_user"
    }
}

private struct EmailTokenRequest: Encodable {
    let email: String
    let token: String
    let type: String
}

private struct AppleTokenRequest: Encodable {
    let provider: String
    let identityToken: String
    let nonce: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case identityToken = "id_token"
        case nonce
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String
    let user: AuthUserResponse

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

private struct AuthUserResponse: Decodable {
    let id: String
    let email: String?
}
