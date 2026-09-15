import SwiftUI

private struct TrainingFuelHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var trainingFuelHosted: Bool {
        get { self[TrainingFuelHostedKey.self] }
        set { self[TrainingFuelHostedKey.self] = newValue }
    }
}

/// Session ownership and presentation stay outside transient journal pages.
/// The turner, route, focus and gesture machinery are not modified.
private struct TrainingFuelHost: ViewModifier {
    @ObservedObject var viewModel: DashboardViewModel
    @StateObject private var model = TrainingFuelModel()
    @Environment(\.scenePhase) private var scenePhase
    private let reader = TrainingFuelHealthReader()

    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .environment(\.trainingFuelHosted, true)
            .sheet(isPresented: Binding(get: { model.isEditing }, set: { if !$0 { model.cancel() } })) {
                TrainingFuelEditor(model: model)
            }
            .onReceive(viewModel.$snapshot) { model.synchronize($0, calendar: .autoupdatingCurrent) }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await refresh() }
            }
    }

    private func refresh() async {
        model.synchronize(viewModel.snapshot, calendar: .autoupdatingCurrent)
        let day = model.day
        let context = await reader.read()
        guard !Task.isCancelled, day == model.day else { return }
        model.context = context
    }
}

extension View {
    func trainingFuel(viewModel: DashboardViewModel) -> some View {
        modifier(TrainingFuelHost(viewModel: viewModel))
    }
}
