import SwiftUI

/// Issue #310 — the shell's restoring surface. While a stored session is still
/// being restored (cold launch, including a token refresh), the shell renders
/// the same paper-skeleton language Today uses for its first read — never
/// onboarding or sign-in. Placeholder blocks only: no data, no date, no chrome
/// and no tab bar.
struct RestoringShellSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TodaySkeleton()
            Spacer(minLength: 0)
        }
        .padding(.leading, 46)
        .padding(.trailing, 18)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .morselJournalPaperUnderlay()
        .background(Color.morselBackground.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your journal")
    }
}
