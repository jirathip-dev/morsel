import SwiftUI

typealias JournalTurnMachine = JournalTurnState<JournalTab>

extension JournalTurnState where Page == JournalTab {
    convenience init(base: JournalTab = .today) {
        self.init(base: base, adjacent: { JournalTabNavigation.adjacent(to: $0, turning: $1) },
                  direction: { JournalTabNavigation.direction(from: $0, to: $1) })
    }
}

/// The existing #174 driver, shared by the tab and date specializations.
@MainActor
func animateJournalTurn<Page>(_ machine: JournalTurnState<Page>,
                              effect: JournalTurnState<Page>.Effect, reduceMotion: Bool = false) {
    let duration = reduceMotion ? JournalTurnSeam.reducedDuration : effect.duration
    withAnimation(reduceMotion ? .easeOut(duration: duration) : .timingCurve(0.2, 0.7, 0.2, 1, duration: duration)) {
        machine.apply(effect)
    }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(duration))
        machine.complete(operation: effect.operation)
    }
}

/// Only the date rail owns vertical day gestures. The food ScrollView owns all
/// vertical gestures begun in its content; horizontal tab gestures still reach the shell.
struct JournalDiaryPage<Content: View>: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject var calendar: JournalCalendarModel
    @StateObject private var machine: JournalTurnState<Date>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    let isActive: Bool
    let openCalendar: () -> Void
    @ViewBuilder let content: Content

    init(model: DashboardViewModel, calendar: JournalCalendarModel, isActive: Bool,
         openCalendar: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.model = model
        self.calendar = calendar
        self.isActive = isActive
        self.openCalendar = openCalendar
        self.content = content()
        _machine = StateObject(wrappedValue: JournalTurnState(
            base: model.selectedDate,
            adjacent: { calendar.adjacent(to: $0, direction: $1) },
            direction: { $0 == $1 ? nil : ($0 < $1 ? .forward : .backward) }
        ))
    }

    var body: some View {
        ZStack {
            Color.morselBackground
            // One retained Today layout/model; previews never mount/read a second day.
            content.modifier(HingeTurnPose(direction: machine.turn?.direction ?? .forward,
                                          progress: machine.turn?.progress ?? 1,
                                          isIncoming: machine.phase == .committing,
                                          vertical: true, reduceMotion: reduceMotion))
            if let turn = machine.turn, !turn.committed {
                Color.morselBackground
                    .modifier(HingeTurnPose(direction: turn.direction, progress: turn.progress,
                                            vertical: true, reduceMotion: reduceMotion))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipped()
        .safeAreaInset(edge: .top, spacing: 0) { dateRail }
        .onChange(of: model.selectedDate) { _, date in machine.selectionChanged(to: date) }
        .onChange(of: machine.turn?.id) { _, _ in
            if let turn = machine.turn, let effect = machine.swingDidAppear(id: turn.id) {
                animateJournalTurn(machine, effect: effect, reduceMotion: reduceMotion)
            }
        }
        .onChange(of: isActive) { _, active in if !active { machine.interrupt() } }
        .onChange(of: reduceMotion) { _, _ in machine.interrupt() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { machine.interrupt() } }
        .onDisappear { machine.interrupt() }
        .task { await calendar.load() }
    }

    private var dateRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                dayButton(.backward, symbol: "chevron.left", label: "Previous day")
                Button(action: openCalendar) {
                    Text(model.selectedDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.morselHand(size: 22))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose diary date")
                .accessibilityValue(model.selectedDate.formatted(date: .complete, time: .omitted))
                dayButton(.forward, symbol: "chevron.right", label: "Next day")
                Button(action: openCalendar) {
                    Image(systemName: "calendar").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).accessibilityLabel("Open calendar")
            }
            Text("swipe here ↑ previous · ↓ next")
                .font(.morselFootnote).foregroundStyle(Color.morselInkTwo)
                .accessibilityHidden(true)
        }
        .padding(.leading, 38).padding(.trailing, 14).padding(.bottom, 6)
        .foregroundStyle(Color.morselInk)
        .background(Color.morselBackground)
        .contentShape(Rectangle())
        .highPriorityGesture(dayGesture, including: voiceOver || !isActive ? .none : .all)
        .accessibilityIdentifier("diary-date-rail")
    }

    private var dayGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                machine.dragChanged(deltaX: -value.translation.height, deltaY: value.translation.width, width: 120)
            }
            .onEnded { value in
                guard let effect = machine.dragEnded(deltaX: -value.translation.height,
                                                      predictedX: -value.predictedEndTranslation.height, width: 120)
                else { return }
                if effect.swipesModel, let turn = machine.turn { model.selectDate(turn.incoming) }
                animateJournalTurn(machine, effect: effect, reduceMotion: reduceMotion)
            }
    }

    private func dayButton(_ direction: PageTurnDirection, symbol: String, label: String) -> some View {
        Button {
            if let date = calendar.adjacent(to: model.selectedDate, direction: direction) { model.selectDate(date) }
        } label: { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(calendar.adjacent(to: model.selectedDate, direction: direction) == nil)
            .accessibilityLabel(label)
    }
}
