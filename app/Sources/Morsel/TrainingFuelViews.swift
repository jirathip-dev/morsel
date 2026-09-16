import CoreText
import SwiftUI

struct TrainingFuelSection: View {
    @ObservedObject var model: TrainingFuelModel

    var body: some View {
        Button { model.openSheet() } label: {
            HStack(spacing: 8) {
                Text(model.rowText).font(TrainingDayType.figures(size: 20))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(Color.morselInk)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { JournalRule() }
            .overlay(alignment: .bottom) { JournalRule() }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("training-day-row")
        .accessibilityHint("Opens Training day")
    }
}

struct TrainingFuelEditor: View {
    @ObservedObject var model: TrainingFuelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            JournalRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    answer
                    JournalRule()
                    readings
                    JournalRule()
                    about
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .font(.morselSerif(size: 19))
        .foregroundStyle(Color.morselInk)
        .background(Color.morselBackground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\((model.day ?? Date()).formatted(date: .abbreviated, time: .omitted)) · TODAY ONLY")
                    .font(.morselSerif(size: 14))
                Text("Training day").font(.morselDisplay)
            }
            Spacer(minLength: 8)
            Button { model.cancel() } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var usualTarget: String {
        guard model.target != nil, let baseline = model.baseline else { return "unavailable" }
        return TrainingFuelModel.amountText(baseline.calorieTargetKcal) + " kcal"
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Today's answer").font(.morselSerif(size: 22, weight: 600))
            VStack(alignment: .leading, spacing: 4) {
                Text("Usual target · \(usualTarget)")
                .font(TrainingDayType.figures(size: 17))
                if let source = model.baseline?.source, model.target != nil {
                    Text(source == .manual ? "Source: your saved manual goal." : "Source: computed from your profile.")
                        .font(.morselSerif(size: 15))
                }
            }
            .foregroundStyle(Color.morselInkTwo)
            if let addition = model.addition, !model.isEditing {
                Text("Confirmed for this day · +\(TrainingFuelModel.amountText(addition)) kcal")
                    .font(TrainingDayType.figures(size: 20))
                HStack(spacing: 16) {
                    action("Edit amount") { model.beginReview() }
                    action("Undo adjustment") { model.undo() }
                }
            } else {
                entry
            }
            Text("This session only · not synced.\nSaved goals and macros stay unchanged.")
                .font(.morselSerif(size: 15)).foregroundStyle(Color.morselInkTwo)
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("For a longer or harder session, enter an addition from your own plan.")
            Text("Add for this day").font(.morselSerif(size: 19, weight: 600))
            HStack(alignment: .firstTextBaseline) {
                TextField("Your amount", text: $model.draft)
                    .keyboardType(.decimalPad)
                    .font(TrainingDayType.figures(size: 26))
                    .accessibilityLabel("Add for this day, kcal")
                    .accessibilityHint(model.validationMessage ?? "Your own plan; no amount suggested")
                    .accessibilityIdentifier("training-fuel-amount")
                    .disabled(model.isPending)
                Text("kcal").font(.morselSerif(size: 17))
            }
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { JournalRule() }
            Text("No amount suggested. This screen cannot assess adequate fuelling.")
                .font(.morselSerif(size: 15)).foregroundStyle(Color.morselInkTwo)
            if model.requiresAcknowledgement {
                Toggle("I choose a day-only change; keep my saved manual goal.", isOn: $model.acknowledgesDayOnly)
                    .font(.morselSerif(size: 17)).tint(.morselAccent)
                    .frame(minHeight: 44)
                    .disabled(model.isPending)
                    .accessibilityIdentifier("training-fuel-consent")
            }
            if let validation = model.validationMessage {
                Text(validation).font(.morselSerif(size: 15)).foregroundStyle(Color.morselOver)
            }
            if model.isPending {
                Text("Applying local note… Target unchanged until confirmation completes.")
                    .font(.morselSerif(size: 15))
            }
            if let error = model.error {
                Text(error).font(.morselSerif(size: 15)).foregroundStyle(Color.morselOver)
            }
            HStack(spacing: 16) {
                Button { Task { await model.confirm() } } label: {
                    Text(model.error == nil ? "Confirm for this day" : "Retry confirmation")
                        .font(.morselSerif(size: 17, weight: 600))
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(model.canConfirm ? Color.morselAccent : Color.morselSurfaceTwo,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(model.canConfirm ? Color.morselLabelOnAccent : Color.morselInkTwo)
                }
                .buttonStyle(.plain)
                .disabled(!model.canConfirm)
                action("Cancel") { model.cancel() }
            }
        }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Readings").font(.morselSerif(size: 22, weight: 600))
            reading("Movement", model.context.movement, failed: model.context.movementFailed)
            JournalRule()
            reading("Workout", model.context.workout, failed: model.context.workoutFailed)
        }
    }

    private func reading(_ title: String, _ value: TrainingFuelReading?, failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(model.isReadingHealth ? "Reading…" : failed ? "Read failed" : TrainingFuelContext.value(value))
                    .font(TrainingDayType.figures(size: 19))
                    .multilineTextAlignment(.trailing)
            }
            if !model.isReadingHealth {
                Text(failed ? "Apple Health · could not read. Try Read Apple Health again."
                     : value?.detail(for: model.day ?? Date()) ?? "Apple Health · no readable data")
                    .font(.morselSerif(size: 15)).foregroundStyle(Color.morselInkTwo)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About this context").font(.morselSerif(size: 22, weight: 600))
            Text("Food-target comparison, not a fuelling assessment.")
            Text("Movement includes activity beyond workouts. It is context, not a calorie bonus.")
            Text("Health may be missing or not shared; that does not mean a rest day. "
                 + "Dates belong to the samples, and checked times describe these reads. "
                 + "Overlap with your usual target is unknown. "
                 + "For a personal fuelling plan, consult a sports dietitian.")
            action("Read Apple Health") {
                Task { await model.readHealth { await TrainingFuelHealthReader().read(requestPermission: true) } }
            }
            .disabled(model.isReadingHealth)
            Text("Local to this signed-in session, not saved to Health or synced. "
                 + "No meal, future goal or historical target changes.")
        }
        .font(.morselSerif(size: 17)).foregroundStyle(Color.morselInkTwo)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).underline().font(.morselSerif(size: 17))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Variant A's local figures only. No shared numeric token or other surface changes.
enum TrainingDayType {
    static func figureFont(size: CGFloat) -> UIFont {
        let base = UIFont(name: "EB Garamond", size: size) ?? UIFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [
            [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
             UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector],
            [UIFontDescriptor.FeatureKey.type: kNumberCaseType,
             UIFontDescriptor.FeatureKey.selector: kUpperCaseNumbersSelector]
        ]])
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }

    static func figures(size: CGFloat) -> Font { Font(figureFont(size: size)) }
}
