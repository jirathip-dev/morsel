import SwiftUI

// v0.4 hotfix (#89): the app is LIGHT-ONLY until the night-ink theme (#90)
// ships. The WindowGroup root consumes this seam through
// .preferredColorScheme(MorselAppearance.scheme), so the forced-light
// mechanism is assertable from the unhosted unit-test bundle (compiled
// against the real source, no rendered scene needed). The device may be in
// Dark appearance; this keeps every surface on the warm paper palette.
enum MorselAppearance {
    static let scheme: ColorScheme = .light
}
