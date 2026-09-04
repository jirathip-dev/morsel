import SwiftUI

// Issue #94: the v0.4 hotfix (#89) forced the app LIGHT-ONLY through this
// seam; the approved V1 design ships Paper and Night-ink themes (plus
// "Follow system"), so the seam now maps a persisted user preference to the
// root color scheme. Paper forces Light appearance (all dynamic tokens
// resolve their Paper variants), Night ink forces Dark (Night-ink variants),
// and Follow system leaves the scheme untouched (tokens follow the device).
// The WindowGroup root consumes this through
// .preferredColorScheme(MorselAppearance.scheme(for:)) — assertable from the
// unhosted unit-test bundle and pinned by the hosted contract probe.
enum MorselThemePreference: String, CaseIterable, Sendable {
    case paper
    case nightInk
    case followSystem

    var title: String {
        switch self {
        case .paper: "Paper"
        case .nightInk: "Night ink"
        case .followSystem: "Follow system"
        }
    }
}

enum MorselAppearance {
    /// Persisted preference key (UserDefaults/@AppStorage).
    static let themePreferenceKey = "morsel.appearance.theme"
    /// V1 ships Paper by default (the approved warm journal ground).
    static let defaultThemePreference: MorselThemePreference = .paper

    /// Root color scheme for a preference: Paper = light, Night ink = dark,
    /// Follow system = nil (no forcing).
    static func scheme(for preference: MorselThemePreference) -> ColorScheme? {
        switch preference {
        case .paper: return .light
        case .nightInk: return .dark
        case .followSystem: return nil
        }
    }
}
