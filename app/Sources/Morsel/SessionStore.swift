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

    /// Issue #310 — the shell's restore phase. Cold launch starts `restoring`:
    /// "no session YET" is a different state from "resolved: no session", and
    /// only a resolved phase may render onboarding or sign-in.
    enum Phase: Equatable, Sendable {
        case restoring
        case signedIn
        case needsSetup
        case needsSignIn
    }

    /// Issue #310 AC4 — why an attempt ended without a session. Explicit, so a
    /// failed or hung token refresh is never collapsed into the same nil as a
    /// genuine no-session result.
    enum RestoreFailure: Equatable, Sendable {
        case refreshFailed
        case timedOut
    }

    @Published private(set) var phase: Phase = .restoring
    @Published private(set) var session: AuthenticatedSession?
    @Published private(set) var pendingRoute: NoSessionRoute = .initialSetup
    private(set) var restoreFailure: RestoreFailure?

    /// Issue #310 AC4 — the bounded restore window: a refresh that never
    /// answers resolves the shell to the sign-in route instead of leaving the
    /// skeleton up forever. Injectable so the bound is exercised as-is.
    private let restoreBound: Duration

    init(restoreBound: Duration = .seconds(10)) {
        self.restoreBound = restoreBound
    }

    var isSetupDeferred: Bool { pendingRoute == .setupDeferred }
    /// The unresolved phase: the shell's paper skeleton is rendered here and
    /// nowhere else, and it is never permanent — every attempt resolves.
    var isRestoring: Bool { phase == .restoring }

    /// Records the deferred route. An already-resolved setup advances to the
    /// sign-in route; an unresolved attempt is left alone so it still resolves
    /// (issue #310 AC3 — a deferred setup reaches sign-in, never a skeleton).
    func deferSetup() {
        pendingRoute = .setupDeferred
        if phase == .needsSetup {
            phase = .needsSignIn
        }
    }

    func authenticate(_ session: AuthenticatedSession) {
        self.session = session
        pendingRoute = .initialSetup
        restoreFailure = nil
        phase = .signedIn
    }

    func signOut(using auth: any SupabaseAuthenticating) async {
        try? await auth.signOut()
        session = nil
        pendingRoute = .setupDeferred
        restoreFailure = nil
        phase = .needsSignIn
    }

    /// Resolves the restoring phase exactly once: a stored session signs in, a
    /// genuine no-session resolves to onboarding (or the deferred sign-in
    /// route), and a failed or hung attempt resolves to sign-in with the
    /// failure recorded (issue #310 AC3/AC4). A late completion never
    /// re-routes a shell that already settled.
    func restore(using auth: any SupabaseAuthenticating) async {
        guard phase == .restoring else {
            return
        }
        let bound = restoreBound
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: bound)
            guard !Task.isCancelled else { return }
            self?.resolveFailure(.timedOut)
        }
        defer { watchdog.cancel() }
        do {
            resolveRestored(try await auth.restoreSession())
        } catch {
            resolveFailure(.refreshFailed)
        }
    }

    private func resolveRestored(_ session: AuthenticatedSession?) {
        guard phase == .restoring else {
            return
        }
        restoreFailure = nil
        guard let session else {
            phase = isSetupDeferred ? .needsSignIn : .needsSetup
            return
        }
        self.session = session
        pendingRoute = .initialSetup
        phase = .signedIn
    }

    private func resolveFailure(_ failure: RestoreFailure) {
        guard phase == .restoring else {
            return
        }
        restoreFailure = failure
        pendingRoute = .setupDeferred
        phase = .needsSignIn
    }
}
