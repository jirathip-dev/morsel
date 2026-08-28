# Morsel iOS dashboard

The native dashboard is a SwiftUI app generated from `project.yml` for iOS 17
and newer. It reads `meal_logs`, `meal_items`, `goals`, and `profiles` through
`supabase-swift` 2.55.1. The SDK owns the authenticated session, persisted
refresh token, and automatic refresh lifecycle; Supabase RLS remains the
ownership boundary. There is no app chat or AI surface.

## Generate and test

```sh
xcodegen generate
xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' CODE_SIGNING_ALLOWED=NO
```

The app target uses `SupabaseDashboardRepository` and `SupabaseAuthClient`
behind small protocols. The adapters use the SDK client, while the protocol
seam keeps mock-backed tests and previews independent of a live Supabase
project. Apple Sign In uses the app entitlement and a hashed request nonce;
the raw nonce is passed to Supabase for ID-token verification.

The repository resolves effective goals after loading the raw rows: a complete
manual goal wins, otherwise the profile is passed through the deterministic
Mifflin-St Jeor → TDEE → diet-goal calculation mirrored in `DashboardMath`.
This intentionally mirrors the server's `compute_targets` helper because its
composite-profile RPC input is not a stable client contract; keeping the
calculation local makes the protocol/mock path testable. With neither a
complete manual goal nor a valid profile, the goal remains unavailable rather
than being invented.

The `Looks right` review action updates the meal item's confidence through the
repository and reloads the day, so the high-confidence state comes from the
store rather than a process-local flag.

Set `MorselSupabaseURL` and `MorselSupabaseAnonKey` in the app target's Info
settings for a configured build. Empty values are intentional in the checked-in
project: the app reports that configuration is missing rather than displaying
invented data.
