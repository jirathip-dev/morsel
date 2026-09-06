import SwiftUI

// Issue #152 — Menus screen: create / edit / delete reusable named menus
// (meal-type-free templates). Rows open the paper editor; deleting asks
// through the same paper confirmation dialog the journal uses. Logging from
// a menu happens on the Add-Meal sheet, not here — this page owns the
// templates only.

struct MenusScreen: View {
    @ObservedObject var model: MenuLibraryModel
    let onClose: () -> Void

    /// Which existing menu the editor sheet edits (nil = the +New sheet).
    @State private var editingMenu: NamedMenu?
    @State private var isCreatingNew = false
    @State private var confirmingDelete: NamedMenu?

    var body: some View {
        JournalPage(date: Date(), bottomInset: 24) {
            VStack(alignment: .leading, spacing: 0) {
                JournalPageHeader(
                    title: "Menus",
                    leadingTitle: "Back",
                    leadingAction: onClose,
                    trailingTitle: "New",
                    trailingAction: { isCreatingNew = true }
                )

                if let error = model.errorMessage {
                    Text(error)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselOver)
                        .padding(.bottom, 10)
                }

                SectionHeading(title: "Your menus")
                    .padding(.vertical, 10)

                if model.isLoading && model.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color.morselAccent)
                        Text("Loading menus")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                } else if model.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No menus yet.")
                            .font(.morselBodyStrong)
                            .foregroundStyle(Color.morselInk)
                        Text("Menus bundle the foods you log often, so you can log a whole "
                             + "set in one tap from the Add Meal sheet.")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(model.menus) { menu in
                        menuRow(menu)
                        if menu.id != model.menus.last?.id {
                            Rectangle()
                                .fill(Color.morselInkLine.opacity(0.35))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            MenuEditorSheet(
                title: "New menu",
                model: model,
                onSaved: { isCreatingNew = false }
            )
        }
        .sheet(item: $editingMenu) {
            MenuEditorSheet(
                title: "Edit menu",
                model: model,
                menu: $0,
                onSaved: { editingMenu = nil }
            )
        }
        .confirmationDialog(
            "Delete this menu?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete menu", role: .destructive) {
                if let menu = confirmingDelete {
                    Task { await model.delete(menuID: menu.menuID) }
                }
                confirmingDelete = nil
            }
        } message: {
            Text("Menus you already logged stay in your journal — only the reusable template is removed.")
        }
        .task { await model.loadMenus() }
    }

    private func menuRow(_ menu: NamedMenu) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(menu.name)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text(menu.summaryLine)
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkThree)
            }
            Spacer(minLength: 8)
            Button("Edit") {
                editingMenu = menu
            }
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselForest)
            .buttonStyle(.plain)
            Button {
                confirmingDelete = menu
            } label: {
                Image(systemName: "trash")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInkThree)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(menu.name)")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
