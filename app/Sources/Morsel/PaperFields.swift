import SwiftUI
import UIKit

// Issue #105 — paper-native input surfaces (AC5). Add Meal, Edit Item, and
// Goals all edit on ruled journal fields instead of stock Form cells: a
// readable serif label, an inkline rule under the value, native keyboards and
// controls, validation states on the rule, Dynamic Type-friendly layout, and
// accessible labels/hints. All colors come from DesignSystem tokens; there is
// no Form, no rounded cell, and no ad-hoc hex here.

/// A ruled journal field: label above, value typed on an inkline rule,
/// optional unit readout, and an error state that re-inks the rule. The
/// caller supplies its own `@FocusState` key so every page owns focus through
/// the shared AC6 contract (Done bar for numeric pads, blank-tap and
/// scroll dismissal).
struct JournalPaperField<Key: Hashable>: View {
    let label: String
    @Binding var text: String
    var focus: FocusState<Key?>.Binding
    var key: Key
    var unit: String?
    var prompt: String?
    var axis: Axis = .horizontal
    var keyboardType: UIKeyboardType = .default
    var monospacedValue = false
    var prominent = false
    var trailingValue = false
    var error: String?
    var hint: String?
    /// Overrides the visible `label` for VoiceOver when the label is hidden
    /// (auth caption rows keep their own uppercase captions).
    var accessibilityLabelOverride: String?
    var onEdit: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !label.isEmpty {
                Text(label)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if trailingValue {
                    Spacer(minLength: 4)
                }
                TextField(accessibilityLabelOverride ?? label, text: binding, prompt: promptText, axis: axis)
                    .focused(focus, equals: key)
                    .font(valueFont)
                    .foregroundStyle(Color.morselInk)
                    .multilineTextAlignment(trailingValue ? .trailing : .leading)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .lineLimit(axis == .vertical ? 1...4 : 1...1)
                    .accessibilityHint(accessibilityHintText)
                if let unit {
                    Text(unit)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselInkTwo)
                }
            }
            Rectangle()
                .fill(ruleColor)
                .frame(height: error == nil ? 1 : 1.4)
            if let error {
                Text(error)
                    .font(.morselData)
                    .foregroundStyle(Color.morselOver)
                    .accessibilityLabel("\\(label) error: \\(error)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var binding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = newValue
                onEdit?(newValue)
            }
        )
    }

    private var promptText: Text? {
        guard let prompt else { return nil }
        return Text(prompt)
    }

    private var valueFont: Font {
        guard monospacedValue else { return .morselBody }
        return prominent ? Font.morselMonoMedium(size: 22) : Font.morselMonoMedium(size: 17)
    }

    private var ruleColor: Color {
        error == nil ? Color.morselInkLine.opacity(0.75) : Color.morselOver
    }

    private var accessibilityHintText: String {
        if let error {
            return error
        }
        return hint ?? ""
    }
}

/// Journal page header for in-flow pages (Add Meal / Edit Item): Cancel or
/// back on the leading side, hand-lettered page title, primary action on the
/// trailing side. Replaces the stock Form navigation chrome with paper words
/// (AC3/AC5) while keeping native button behavior.
struct JournalPageHeader: View {
    let title: String
    let leadingTitle: String
    let leadingAction: () -> Void
    let trailingTitle: String?
    let trailingDisabled: Bool
    let trailingAction: (() -> Void)?

    init(
        title: String,
        leadingTitle: String,
        leadingAction: @escaping () -> Void,
        trailingTitle: String? = nil,
        trailingDisabled: Bool = false,
        trailingAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.leadingTitle = leadingTitle
        self.leadingAction = leadingAction
        self.trailingTitle = trailingTitle
        self.trailingDisabled = trailingDisabled
        self.trailingAction = trailingAction
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: leadingAction) {
                Text(leadingTitle)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselForest)
            }
            .buttonStyle(.plain)
            .morselResignsKeyboardOnTap()
            .frame(width: 88, alignment: .leading)
            .accessibilityHint("Closes this page")

            Spacer(minLength: 0)
            Text(title)
                .font(.morselDisplay)
                .foregroundStyle(Color.morselInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)

            Group {
                if let trailingTitle, let trailingAction {
                    Button(action: trailingAction) {
                        Text(trailingTitle)
                            .font(.morselBodyStrong)
                            .foregroundStyle(trailingDisabled ? Color.morselInkThree : Color.morselForest)
                    }
                    .buttonStyle(.plain)
                    .disabled(trailingDisabled)
                    .morselResignsKeyboardOnTap()
                }
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.bottom, 14)
    }
}
