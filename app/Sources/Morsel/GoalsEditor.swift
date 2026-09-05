// swiftlint:disable line_length
import SwiftUI

enum GoalDirection: String, CaseIterable, Sendable {
    case cut
    case maintain
    case bulk

    /// Issue #123 — the phase a profile diet goal implies
    /// (lose→cut / maintain→maintain / gain→bulk).
    init(profileDietGoal: ProfileDietGoal) {
        switch profileDietGoal {
        case .lose: self = .cut
        case .maintain: self = .maintain
        case .gain: self = .bulk
        }
    }

    var title: String {
        switch self {
        case .cut: "Cut"
        case .maintain: "Maintain"
        case .bulk: "Bulk"
        }
    }
    var subtitle: String {
        switch self {
        case .cut: "steady loss"
        case .maintain: "hold steady"
        case .bulk: "steady gain"
        }
    }
}

// Issue #94: Goals is a PRIMARY tab (journal editor page). See-it -> Today.
private enum GoalsFieldKey: Hashable { case calories, protein, carbs, fat }
struct GoalsView: View {
    @StateObject private var viewModel: GoalsEditorViewModel
    private let reloadKey: Int  // Issue #105: pager-revisit reload bump
    @FocusState private var focusedField: GoalsFieldKey?
    init(
        repository: any DashboardRepository,
        userID: UUID,
        reloadKey: Int = 0,
        onSaved: @escaping () async -> Void = {},
        seeToday: @escaping () -> Void = {}
    ) {
        self.reloadKey = reloadKey
        _viewModel = StateObject(
            wrappedValue: GoalsEditorViewModel(
                repository: repository, userID: userID, onSaved: onSaved, onSeeToday: seeToday
            )
        )
    }

    var body: some View {
        JournalPage(date: Date(), bottomInset: 56) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text("What are we aiming for?")
                    .font(Font.morselHand(size: 30))
                    .foregroundStyle(Color.morselInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Pick a direction, then change any number before I save it.")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
                directions
                if viewModel.isAwaitingFirstGoal {
                    // Issue #123 — very first load with no cached row yet:
                    // a calm loading state instead of empty inputs and
                    // per-field validation.
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color.morselAccent)
                        Text("Opening your goals…")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    Text("Your target").morselSectionLabel()
                    if let supersededNote = viewModel.supersededNote {
                        // Issue #113: calm one-line note when the profile update
                        // superseded an older manual goal.
                        Text(supersededNote)
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GoalJournalField(
                        label: "Calories",
                        unit: "kcal",
                        value: $viewModel.calories,
                        focus: $focusedField,
                        key: .calories,
                        source: viewModel.sources["calories"],
                        error: viewModel.fieldError("calories"),
                        prominent: true
                    ) { viewModel.edit("calories", value: $0) }
                    HStack(alignment: .top, spacing: 14) {
                        GoalJournalField(label: "Protein", unit: "g", value: $viewModel.protein, focus: $focusedField, key: .protein, source: viewModel.sources["protein"], error: viewModel.fieldError("protein")) { viewModel.edit("protein", value: $0) }
                        GoalJournalField(label: "Carbs", unit: "g", value: $viewModel.carbs, focus: $focusedField, key: .carbs, source: viewModel.sources["carbs"], error: viewModel.fieldError("carbs")) { viewModel.edit("carbs", value: $0) }
                        GoalJournalField(label: "Fat", unit: "g", value: $viewModel.fat, focus: $focusedField, key: .fat, source: viewModel.sources["fat"], error: viewModel.fieldError("fat")) { viewModel.edit("fat", value: $0) }
                    }
                    if let profileLine = viewModel.profileLine {
                        // Issue #113 amendment B: read-only profile provenance line.
                        Text(profileLine)
                            .font(.morselFootnote)
                            .foregroundStyle(Color.morselInkTwo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !viewModel.isValid {
                        Text("One more pass…")
                            .foregroundStyle(Color.morselOver)
                            .font(.morselBody)
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color.morselOver)
                            .font(.morselBody)
                    }
                    if viewModel.didSave {
                        Text("Goals saved ✓")
                            .foregroundStyle(Color.morselForest)
                            .font(.morselBodyStrong)
                    }
                    Button(viewModel.didSave ? "Goals saved ✓" : "Use these goals") {
                        JournalKeyboardDismisser.resign()
                        Task { await viewModel.save() }
                    }
                    .buttonStyle(MorselPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.isValid || viewModel.isSaving)
                    Text("What changes").morselSectionLabel()
                    Text(viewModel.whatChangesText)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselInkTwo)
                    Button {
                        viewModel.seeToday()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("See it")
                                .font(.morselFootnote)
                                .foregroundStyle(Color.morselForest)
                            MarkerStroke(color: Color.morselForest, width: 40, height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .morselResignsKeyboardOnTap()
                    .accessibilityLabel("See today's readout")
                }
            }
        }
        .morselNumericDoneBar(focused: $focusedField) { _ in .numbersAndPunctuation }
        .task(id: reloadKey) { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily goals")
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
                Text(viewModel.sourceIndicator)
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
            }
            Spacer()
            Text("morsel · agent voice")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkThree)
        }
        .padding(.bottom, 6)
    }
    private var directions: some View {
        HStack(spacing: 6) {
            ForEach(GoalDirection.allCases, id: \.self) { direction in
                let isFilled = viewModel.selectedDirection == direction
                // Issue #123 — when a manual goal is effective nothing is
                // filled; the phase the profile diet goal implies renders as
                // this lighter "profile" hint chip instead.
                let isProfileHint = viewModel.selectedDirection == nil
                    && viewModel.profileDirection == direction
                Button {
                    Task { await viewModel.choose(direction) }
                } label: {
                    VStack(spacing: 2) {
                        Text(direction.title)
                            .font(Font.morselHand(size: 20))
                            .foregroundStyle(
                                isFilled ? Color.morselForest
                                    : isProfileHint ? Color.morselForest.opacity(0.45)
                                    : Color.morselInk
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                isFilled
                                    ? Color.morselForest.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        Text(direction.subtitle)
                            .font(.morselFootnote)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .morselResignsKeyboardOnTap()
                .accessibilityAddTraits(isFilled ? .isSelected : [])
            }
        }
    }
}

private struct GoalJournalField<Key: Hashable>: View {
    let label: String
    let unit: String
    @Binding var value: String
    var focus: FocusState<Key?>.Binding
    var key: Key
    let source: GoalSource?
    let error: String?
    var prominent = false
    let onEdit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            JournalPaperField(  // Issue #105: shared ruled paper field
                label: label,
                text: $value,
                focus: focus,
                key: key,
                unit: unit,
                keyboardType: .numbersAndPunctuation,
                monospacedValue: true,
                prominent: prominent,
                trailingValue: true,
                error: error,
                onEdit: onEdit
            )
            HStack {
                ProvenanceLabel(text: "source: \(source?.rawValue ?? "—")")
            }
        }
    }
}

// swiftlint:enable line_length
