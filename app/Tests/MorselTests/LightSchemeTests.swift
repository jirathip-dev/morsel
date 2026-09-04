import XCTest
@testable import Morsel

// v0.4 hotfix #89 (r1 review): issue #89 acceptance requires an XCTest
// asserting the light-scheme mechanism so it cannot regress silently. The
// mechanism is the root `.preferredColorScheme(MorselAppearance.scheme)`
// on the WindowGroup content in MorselApp.swift (a UIUserInterfaceStyle
// plist key would require editing the fastlane INFOPLIST_FILE template —
// release tooling, out of scope). `MorselAppearance.scheme` is the small
// testable seam consumed by that root modifier; this test compiles against
// the real source in the unhosted unit-test bundle (no rendered scene).
// Root PLACEMENT is pinned by the hosted probe in app/hotfix-89-contract.test.ts
// (a seam value change fails natively; moving the modifier to a descendant
// surface fails the hosted root-chain assertion).
final class LightSchemeTests: XCTestCase {
    func testRootAppearanceSeamIsLight() {
        XCTAssertEqual(MorselAppearance.scheme, .light)
    }

    func testRootAppearanceSeamNeverDark() {
        XCTAssertNotEqual(MorselAppearance.scheme, .dark)
    }
}
