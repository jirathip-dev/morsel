# Morsel iOS dashboard

The native dashboard is a SwiftUI app generated from `project.yml` for iOS 17
and newer. It reads `meal_logs`, `meal_items`, and `goals` directly from
Supabase with the signed-in user's bearer token, so Supabase RLS remains the
ownership boundary. There is no app chat or AI surface.

## Generate and test

```sh
xcodegen generate
xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

The app target uses `SupabaseDashboardRepository` and `SupabaseAuthClient`
behind small protocols. The adapters use Foundation's URL loading APIs so the
project and its mock-backed tests/previews do not need a package checkout or a
live Supabase project. The seam can adopt `supabase-swift` when the live auth
and data verification work lands.

Set `MorselSupabaseURL` and `MorselSupabaseAnonKey` in the app target's Info
settings for a configured build. Empty values are intentional in the checked-in
project: the app reports that configuration is missing rather than displaying
invented data.
