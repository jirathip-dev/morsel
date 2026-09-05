import XCTest
@testable import Morsel

// Issue #126 (AC3): GoTrue's raw "Error sending confirmation email" text must
// never reach the user. The email-OTP send path maps every failure through
// DashboardUserMessage — the #94 AC5 friendly boundary — so the known GoTrue
// email-send failure reads as calm, actionable copy, and any other auth error
// falls back to the calm generic. This file is RED at the pre-change base
// (base returned the generic message for the GoTrue marker error) and GREEN
// once the boundary maps the marker.
final class AuthEmailErrorCopyTests: XCTestCase {
    /// Fake whose email-OTP send throws exactly the GoTrue failure text that
    /// escaped verbatim to the sign-in UI before this mapping.
    private struct EmailSendFailureAuth: SupabaseAuthenticating {
        func restoreSession() async throws -> AuthenticatedSession? { nil }

        func requestEmailOTP(email: String) async throws {
            throw NSError(
                domain: "supabase.gotrue",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Error sending confirmation email"]
            )
        }

        func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession {
            AuthenticatedSession(userID: UUID(), email: email)
        }

        func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession {
            AuthenticatedSession(userID: UUID(), email: nil)
        }
    }

    func testGoTrueEmailSendFailureShowsCalmActionableCopy() async {
        let auth = EmailSendFailureAuth()

        do {
            try await auth.requestEmailOTP(email: "tester@example.com")
            XCTFail("A failing email-OTP send must throw.")
        } catch {
            let shown = DashboardUserMessage.userMessage(for: error)

            XCTAssertEqual(
                shown,
                "We couldn't email a code to that address right now — try again in a minute or use Sign in with Apple."
            )
            XCTAssertFalse(shown.contains("Error sending"), "raw GoTrue text must never reach the user")
        }
    }

    func testOtherAuthErrorsFallBackToCalmGenericNeverRawText() {
        let rawTokenError = NSError(
            domain: "supabase.gotrue",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Token has expired or is invalid"]
        )

        let shown = DashboardUserMessage.userMessage(for: rawTokenError)

        XCTAssertEqual(shown, DashboardUserMessage.unexpected)
        XCTAssertFalse(shown.contains("Token has expired"))
    }

    func testMorselErrorCuratedCopyStillPassesThroughTheBoundary() {
        let shown = DashboardUserMessage.userMessage(
            for: MorselError.invalidInput("Enter a valid email address.")
        )

        XCTAssertEqual(shown, "Enter a valid email address.")
    }
}
