# Issue #125 evidence — Sign in with Apple button tap regression

Repo-local evidence for the issue #125 lane (issue/125-apple-signin). The
regression: `morselResignsKeyboardOnTap()` — a SwiftUI
`simultaneousGesture(TapGesture())` — attached to `SignInWithAppleButton`
swallowed the UIKit-hosted `ASAuthorizationAppleIDButton`'s own tap, so the
Apple authorization sheet never presented (TestFlight builds 5+6; email OTP
kept working because those buttons are native SwiftUI).

## Fix

- `app/Sources/Morsel/AuthView.swift`: removed `.morselResignsKeyboardOnTap()`
  from the `SignInWithAppleButton` block; keyboard dismissal moved into
  `configureApple` (the `onRequest` phase) via
  `JournalKeyboardDismisser.resign()` — #105 AC6 intent preserved without
  touching the UIKit hit-test.
- UIKit-control audit (issue AC2): the only other UIKit-hosted surfaces are
  `CameraPicker` (`UIViewControllerRepresentable` over
  `UIImagePickerController`, presented full-screen from a native Button that
  resigns inside its own action) and SwiftUI `PhotosPicker` (native label
  control, no resign modifier). All remaining
  `.morselResignsKeyboardOnTap()` sites sit on native SwiftUI controls
  (Buttons, menu Pickers, DatePicker rows) where the gesture is safe. No
  other real instances.

## Real-tap simulator evidence (XCUITest, throwaway driver)

The host has no touch-injection tool (documented limitation in the #105
README), so a THROWAWAY UI-test target (`MorselUITests`, own scheme) drove
REAL taps on the app-lane iPhone 16 simulator (UDID
`59DDC0C5-891E-4EC0-91AF-4F50DF68D793`, unsigned Debug,
`CODE_SIGNING_ALLOWED=NO`, 393×852 pt @3x = 1179×2556 px). The driver
(`app/Tests/MorselUITests/AppleSignInEvidenceUITests.swift`) and the
`project.yml` target/scheme were REMOVED after capture — the committed tree
carries only these screenshots. Captured 2026-09-05 (+07).

| file | build | what it shows |
| --- | --- | --- |
| `125-00-signin-standalone.png` | fixed | standalone sign-in page reached by tapping "Set up later" (Apple button, `or email`, EMAIL field) |
| `125-01-email-focused-keyboard.png` | fixed | email field focused — software keyboard up |
| `125-02-email-validation.png` | fixed | email path still works: typing `nope` + "Send email code" shows the client-side "Enter a valid email address." message |
| `125-03-email-focused-before-apple.png` | fixed | email field re-focused (keyboard up again) immediately before the Apple tap |
| `125-04-after-apple-tap-auth-engaged.png` | fixed | AFTER tapping "Sign in with Apple" while the keyboard was up: keyboard dismissed AND AuthenticationServices engaged — in-app `AuthorizationError error 1000` from `completeApple` proves the UIKit button received the tap and the authorization controller ran |
| `125-base-after-apple-tap.png` | base `c512b0f` | SAME real tap on the pre-fix wiring: keyboard dismissed by the resign gesture, but NO authorization engagement (no error, no sheet) — the dead button from the issue |

SHA-256 (evidence images):

```
719d9801a0bee5f7ccb8bec7afd9b5283a3d8d5aa1f02961836feda60e5f0b60  125-00-signin-standalone.png
c7ced5566c38ade82834675d7c7e17aaf50df0f9e693b8e89cfa76d871fdac66  125-01-email-focused-keyboard.png
6f4137701eb57d5da9478d981254a4f9a8abc857bac8e8aa0fc0892952c8a60d  125-02-email-validation.png
70d681624097298cd1fe03eea38dd209745215043fb603e33915a918e0943c52  125-03-email-focused-before-apple.png
b1d713e4cf6ecd43001b613a6044898a2a454adf19dba3ec18ab86a7e8589dfb  125-04-after-apple-tap-auth-engaged.png
0c227bf81b282b98122bdfe923bd92c6d301bf2509bf16da5203f55aece8e0d7  125-base-after-apple-tap.png
```

Interactive RED/GREEN pair (raw exits in `logs/`):

- BASE (`c512b0f` wiring, test `testBaseBuildAppleTapStaysDead`): **PASS —
  the bug reproduces** — tap engages nothing. `xcodebuild test … exit 0`
  (`logs/ui-base-build.log`).
- FIXED head (test `testAppleButtonTapEvidenceFlow`): **PASS — the tap now
  reaches the button**: keyboard resigns and authorization engages. Exit 0
  (`logs/ui-fixed-head.log`).

## Honest limitation: the Apple sheet itself cannot present on this sim

`ASAuthorizationAppleIDButton` on the unsigned simulator build engages the
authorization controller, but the remote authorization SHEET needs the app
signed with a provisioning profile carrying
`com.apple.developer.applesignin` — ad-hoc codesigning with that entitlement
is rejected by SpringBoard on launch (verified), and no development profile
exists on this lane host. Full sheet presentation + a returned Supabase
session is the issue's own human gate (next TestFlight build on a real
device). The end-to-end tap path (UIKit button hit-test → `onRequest` →
resign + controller run) is what the fix changed, and it is proven above;
"email OTP still works" is proven at the app level (validation message);
actual OTP delivery needs a live Supabase project + mailbox (device gate).

## Regression proof (source wiring test, RED at base → GREEN at head)

`app/issue-125-apple-signin-contract.test.ts` (hosted vitest probe, npm test
surface) pins that the `SignInWithAppleButton` block in `AuthView.swift`
carries NO `.morselResignsKeyboardOnTap()`/`simultaneousGesture` and that
`configureApple` calls `JournalKeyboardDismisser.resign()`.

- RED at `c512b0f` (test added, fix absent): 2 failed (2), raw exit 1 —
  `logs/red-base-probe.log`.
- GREEN at head: 2 passed (2), raw exit 0 — `logs/green-head-probe.log`.
- Mutation (temporarily re-adding `.morselResignsKeyboardOnTap()` to the
  SIWA block): 1 failed | 1 passed, raw exit 1 — `logs/red-mutation-probe.log`.

## Gate results at the implementation head (commit `7427ab3`)

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| Repo vitest (hosted-CI mirror, node 22) | `npm test` | 0 — 443/443 (39 files) | `logs/gate-npm-test.log` |
| Hosted app probes | `npx vitest run app/*.test.ts` (11 files) | 0 — 82/82 | `logs/gate-vitest-app-probes.log` |
| XcodeGen byte stability | `cd app && xcodegen generate` (pbxproj `git diff` = 0 lines) | 0 | `logs/gate-xcodegen.log` |
| Native build/test (iPhone 16 sim, unsigned) | `herdr-xcodebuild test … CODE_SIGNING_ALLOWED=NO` (DIRECT) | 0 — 169 tests, 0 failures, `** TEST SUCCEEDED **` | `logs/gate-xcodebuild-test.log` |
| SwiftLint strict | `cd app && swiftlint lint --strict --quiet` | 0 | `logs/gate-swiftlint.log` |
| Whitespace | `git diff --check` | 0 | `logs/gate-diff-check.log` |

Note: bare `xcodebuild` in this fleet pane is intercepted by the agent shim
and rerouted to a private temporary simulator, so the native gate ran through
`herdr-xcodebuild` with `HERDR_XCODEBUILD_DIRECT=1` (external DerivedData
cache per `.herdr-build-cache.json`, real `xcodebuild`, pinned lane sim UDID).

## Files touched by the lane

- `app/Sources/Morsel/AuthView.swift` (fix)
- `app/issue-125-apple-signin-contract.test.ts` (new hosted probe)
- `docs/evidence/issue-125/` (this evidence)

Scope fence respected: no `server/**`, `db/**`, `skills/**`,
`packages/schema/**`, release tooling, or `docs/` outside evidence. Refs #125.
