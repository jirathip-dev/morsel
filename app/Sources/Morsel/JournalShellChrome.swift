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
                        JournalTabCellLabel(tab: tab, isActive: pager.selection == tab)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(pager.selection == tab ? .isSelected : [])
                }
            }
            .frame(height: 44)
        }
        .background(Color.morselBackground.ignoresSafeArea())
    }
}

/// Issue #177 — one tab cell's interactive label: the V1 word + marker are
/// stretched to the cell's whole allocated region (full width of its column,
/// 44pt tall) so blank space and the cell's corners activate that tab. The
/// word keeps the same hand type, forest/ink colours and 2pt hand offset the
/// approved bar already used.
struct JournalTabCellLabel: View {
    let tab: JournalTab
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(tab.title)
                .font(Font.morselHand(size: 20))
                .foregroundStyle(isActive ? Color.morselForest : Color.morselInkTwo)
            MarkerStroke(
                color: isActive ? Color.morselForest : .clear,
                width: 40,
                height: 4
            )
        }
        .padding(.vertical, 2)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}
