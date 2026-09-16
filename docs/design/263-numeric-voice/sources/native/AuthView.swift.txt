import AuthenticationServices
import SwiftUI
import UIKit

struct SignInView: View {
    let auth: any SupabaseAuthenticating
    let onAuthenticated: (AuthenticatedSession) -> Void

    /// Editable keys for the shared AC6 focus contract (email + code).
    private enum AuthFieldKey: Hashable {
        case email, code
    }

    @FocusState private var focusedField: AuthFieldKey?

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
                            .foregroundStyle(Color.morselForest)
                        Text("Your food record,\nread honestly.")
                            .font(.morselDisplay)
                            .foregroundStyle(Color.morselInk)
                        Text("Sign in to read the meals your agent has written to your store.")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }

                    // Issue #125: SignInWithAppleButton is a UIKit-hosted
                    // ASAuthorizationAppleIDButton — no resign-tap gesture here
                    // (a SwiftUI simultaneousGesture on it swallowed the button
                    // tap). Keyboard dismissal runs in configureApple instead.
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
                        JournalPaperField(
                            label: "",
                            text: $email,
                            focus: $focusedField,
                            key: .email,
                            prompt: "you@example.com",
                            keyboardType: .emailAddress,
                            accessibilityLabelOverride: "Email address"
                        )
                        .disabled(step == .code || isWorking)
                        .opacity(step == .code || isWorking ? 0.6 : 1)

                        if step == .code {
                            Text("CODE")
                                .morselSectionLabel()
                                .padding(.top, 6)
                            JournalPaperField(
                                label: "",
                                text: $code,
                                focus: $focusedField,
                                key: .code,
                                prompt: "Six-digit code",
                                keyboardType: .numberPad,
                                accessibilityLabelOverride: "Sign-in code"
                            )
                            .disabled(isWorking)
                            .opacity(isWorking ? 0.6 : 1)
                            Button("Use a different email") {
                                step = .email
                                code = ""
                                message = nil
                            }
                            .font(.morselData)
                            .foregroundStyle(Color.morselForest)
                            .morselResignsKeyboardOnTap()
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
                    .morselResignsKeyboardOnTap()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .morselBlankSpaceDismissesKeyboard()
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Color.morselBackground.ignoresSafeArea())
        }
        .morselNumericDoneBar(focused: $focusedField, keyboardType: keyboardType(for:))
    }

    private func keyboardType(for key: AuthFieldKey) -> UIKeyboardType {
        switch key {
        case .email:
            return .emailAddress
        case .code:
            return .numberPad
        }
    }

    private func configureApple(_ request: ASAuthorizationAppleIDRequest) {
        // Issue #125: resign here (the onRequest phase) instead of via
        // .morselResignsKeyboardOnTap() on the UIKit-hosted button — the
        // gesture swallowed its tap; dismissal intent (#105 AC6) survives.
        JournalKeyboardDismisser.resign()
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
                message = DashboardUserMessage.userMessage(for: error)
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
                message = DashboardUserMessage.userMessage(for: error)
            }
            isWorking = false
        }
    }

    private func finishAppleSignIn(token: String, nonce: String) async {
        do {
            let session = try await auth.signInWithApple(identityToken: token, nonce: nonce)
            onAuthenticated(session)
        } catch {
            message = DashboardUserMessage.userMessage(for: error)
        }
        isWorking = false
    }
}

private enum AuthStep {
    case email
    case code
}
