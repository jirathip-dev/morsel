import SwiftUI

struct TrainingFuelSection: View {
    @ObservedObject var model: TrainingFuelModel
    var refreshHealth: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrainingFuelReceipt(model: model)
            Text("Food-target comparison, not a fuelling assessment.")
                .font(.morselFootnote)
            JournalRule()
            reading("Movement", model.context.movement)
            reading("Workout", model.context.workout)
            Text("Movement includes activity beyond workouts. It is context, not a calorie bonus.")
                .font(.morselFootnote)
            DisclosureGroup("About this context") {
                Text("Health may be missing or not shared; that does not mean a rest day. "
                     + "Dates belong to the samples, and checked times describe these reads. "
                     + "Overlap with your usual target is unknown. "
                     + "For a personal fuelling plan, consult a sports dietitian.")
                    .font(.morselBody)
                Button("Read Apple Health", action: refreshHealth)
                    .buttonStyle(MorselGhostButtonStyle())
                    .frame(minHeight: 44)
            }
            Toggle("I consider today a longer or harder training day", isOn: $model.longerDay)
                .font(.morselBody)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.addition != nil ? "Today-only note confirmed" : model.longerDay
                     ? "Longer session — review today's fuelling?" : "Usual target unchanged")
                    .font(.morselTitle)
                Text("No amount suggested.").font(.morselFootnote)
                Button(model.addition == nil ? "Review today's plan" : "Edit today's note") { model.beginReview() }
                    .buttonStyle(MorselGhostButtonStyle())
                    .frame(minHeight: 44)
                    .disabled(model.target == nil)
                if model.addition != nil {
                    Button("Undo adjustment") { model.undo() }
                        .buttonStyle(MorselGhostButtonStyle())
                        .frame(minHeight: 44)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.morselInkLine).frame(width: 2)
            }
            Text("This session only · not synced. Saved goals and macros stay unchanged.")
                .font(.morselFootnote)
        }
        .foregroundStyle(Color.morselInkTwo)
        .padding(.top, 16)
    }

    private func reading(_ title: String, _ value: TrainingFuelReading?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(TrainingFuelContext.value(value))")
                .font(.morselBodyStrong).foregroundStyle(Color.morselInk)
            Text(value?.detail(for: model.day ?? Date()) ?? "Apple Health · no readable data")
                .font(.morselFootnote)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TrainingFuelReceipt: View {
    @ObservedObject var model: TrainingFuelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let day = model.day {
                Text(day.formatted(date: .abbreviated, time: .omitted)).font(.morselFootnote)
            }
            row("Usual \(model.baseline?.source.rawValue ?? "unavailable") target", model.baseline?.calorieTargetKcal)
            row("Confirmed for this day", model.addition, prefix: "+", absent: "Not confirmed")
            row("Today's food target", model.target)
        }
        .foregroundStyle(Color.morselInk)
    }

    private func row(_ label: String, _ value: Double?, prefix: String = "",
                     absent: String = "Unavailable") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.morselBody)
            Spacer(minLength: 8)
            Text(value.map { "\(prefix)\($0.formatted()) kcal" } ?? absent)
                .font(.morselData).fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct TrainingFuelEditor: View {
    @ObservedObject var model: TrainingFuelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Today's fuelling note").font(.morselDisplay)
                TrainingFuelReceipt(model: model)
                Text("No amount suggested. Enter an addition from your own plan. "
                     + "This screen cannot assess adequate fuelling.").font(.morselBody)
                Text("Add to this day's food target (kcal)").font(.morselBodyStrong)
                TextField("Your amount", text: $model.draft)
                    .keyboardType(.decimalPad)
                    .font(.morselDataMedium)
                    .padding(12)
                    .background(Color.morselSurfaceTwo, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityIdentifier("training-fuel-amount")
                    .disabled(model.isPending)
                if model.requiresAcknowledgement {
                    Toggle("I choose a day-only change; keep my saved manual goal.", isOn: $model.acknowledgesDayOnly)
                        .font(.morselBody)
                        .disabled(model.isPending)
                        .accessibilityIdentifier("training-fuel-consent")
                }
                if model.isPending {
                    Text("Applying local note… Target unchanged until confirmation completes.").font(.morselBody)
                }
                if let error = model.error {
                    Text(error).font(.morselBody).foregroundStyle(Color.morselOver)
                }
                Button(model.error == nil ? "Confirm for this day" : "Retry confirmation") {
                    Task { await model.confirm() }
                }
                .buttonStyle(MorselPrimaryButtonStyle())
                .frame(minHeight: 44)
                .disabled(!model.canConfirm)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(MorselGhostButtonStyle())
                    .frame(minHeight: 44)
                Text("Local to this signed-in session, not saved to Health or synced. "
                     + "No meal, future goal or historical target changes.").font(.morselFootnote)
            }
            .padding(24)
        }
        .foregroundStyle(Color.morselInk)
        .background(Color.morselBackground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }
}
