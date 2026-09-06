import SwiftUI

// Issue #152 — shell chrome (moved out of MorselApp.swift so shipped files
// stay inside the repo lint budgets): the scoped action tint and the custom
// journal tab bar read the same pager model as the page turner.

/// Scoped orange action tint — tab content keeps the V1 orange identity
/// anchor (never a green wash over descendants).
struct MorselActionTint<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .tint(Color.morselAccent)
    }
}

struct JournalTabBar: View {
    @ObservedObject var pager: JournalPagerModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.morselInkLine.opacity(0.55))
                .frame(height: 1)
            HStack(spacing: 0) {
                ForEach(JournalTab.allCases, id: \.self) { tab in
                    Button {
                        pager.select(tab)
                        JournalKeyboardDismisser.resign()
                    } label: {
                        tabLabel(tab)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(pager.selection == tab ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(height: 44)
        }
        .background(Color.morselBackground.ignoresSafeArea())
    }

    private func tabLabel(_ tab: JournalTab) -> some View {
        let active = pager.selection == tab
        return VStack(spacing: 3) {
            Text(tab.title)
                .font(Font.morselHand(size: 20))
                .foregroundStyle(active ? Color.morselForest : Color.morselInkTwo)
            MarkerStroke(
                color: active ? Color.morselForest : .clear,
                width: 40,
                height: 4
            )
        }
        .padding(.vertical, 2)
    }
}
