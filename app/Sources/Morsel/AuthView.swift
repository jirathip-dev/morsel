import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let auth: any SupabaseAuthenticating
    let onAuthenticated: (AuthenticatedSession) -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var step = AuthStep.email
    @State private var isWorking = false
    @State private var message: String?
    @State private var appleNonce: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("morsel")
                            .font(.morselData)
                            .foregroundStyle(Color.morselAccent)
                        Text("Your food record,\nread honestly.")
                            .font(.morselDisplay)
                            .foregroundStyle(Color.morselInk)
                        Text("Sign in to read the meals your agent has written to your store.")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }

                    SignInWithAppleButton(.signIn, onRequest: configureApple, onCompletion: completeApple)
                        .frame(height: 40)
                        .disabled(isWorking)

                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(Color.morselLine)
                            .frame(height: 1)
                        Text("or email")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkThree)
                        Rectangle()
                            .fill(Color.morselLine)
                            .frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("EMAIL")
                            .morselSectionLabel()
                        TextField("you@example.com", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textFieldStyle(.roundedBorder)
                            .disabled(step == .code || isWorking)

                        if step == .code {
                            Text("CODE")
                                .morselSectionLabel()
                                .padding(.top, 6)
                            TextField("Six-digit code", text: $code)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isWorking)
                            Button("Use a different email") {
                                step = .email
                                code = ""
                                message = nil
                            }
                            .font(.morselData)
                            .foregroundStyle(Color.morselAccent)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.morselBody)
                            .foregroundStyle(Color.morselOver)
                    }

                    Button(step == .email ? "Send email code" : "Verify code") {
                        if step == .email {
                            requestCode()
                        } else {
                            verifyCode()
                        }
                    }
                    .buttonStyle(MorselPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(isWorking)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color.morselBackground.ignoresSafeArea())
        }
    }

    private func configureApple(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.email, .fullName]
        let nonce = AppleNonce.random()
        appleNonce = nonce
        request.nonce = AppleNonce.sha256(nonce)
    }

    private func completeApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let token = String(data: identityToken, encoding: .utf8),
                  let nonce = appleNonce else {
                message = "Apple sign-in did not return an identity token."
                return
            }
            isWorking = true
            message = nil
            Task {
                await finishAppleSignIn(token: token, nonce: nonce)
            }
        case let .failure(error):
            message = error.localizedDescription
        }
    }

    private func requestCode() {
        isWorking = true
        message = nil
        Task {
            do {
                try await auth.requestEmailOTP(email: email)
                step = .code
                message = "Check your email for a sign-in code."
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func verifyCode() {
        isWorking = true
        message = nil
        Task {
            do {
                let session = try await auth.verifyEmailOTP(email: email, code: code)
                onAuthenticated(session)
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func finishAppleSignIn(token: String, nonce: String) async {
        do {
            let session = try await auth.signInWithApple(identityToken: token, nonce: nonce)
            onAuthenticated(session)
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }
}

private enum AuthStep {
    case email
    case code
}
