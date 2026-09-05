import SwiftUI

// Authenticated-session state for the app shell. Kept out of MorselApp.swift
// so the root WindowGroup slice (WindowGroup → MorselConfiguration) stays a
// tight probe target and the shell file stays under the SwiftLint
// file_length ceiling as new seams (issue #110 cover scheme re-assertion)
// land in the dashboard shell.
@MainActor
final class SessionStore: ObservableObject {
    enum NoSessionRoute: Equatable, Sendable {
        case initialSetup
        case setupDeferred
    }

    @Published private(set) var session: AuthenticatedSession?
    @Published private(set) var pendingRoute: NoSessionRoute = .initialSetup

    var isSetupDeferred: Bool { pendingRoute == .setupDeferred }

    func deferSetup() {
        pendingRoute = .setupDeferred
    }

    func authenticate(_ session: AuthenticatedSession) {
        self.session = session
        pendingRoute = .initialSetup
    }

    func signOut(using auth: any SupabaseAuthenticating) async {
        try? await auth.signOut()
        session = nil
        pendingRoute = .setupDeferred
    }

    func restore(using auth: any SupabaseAuthenticating) async {
        guard session == nil else {
            return
        }
        session = try? await auth.restoreSession()
    }
}
