import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #196 — mounted shell cycles. The REAL turner, stage, tab bar, route
// model and presentation owner are mounted in a phone-sized window; the page
// area is wired exactly like `AuthenticatedDashboardView` (#176 precedent).
//
// Touch synthesis is unavailable on this host (#174/#177), so gestures are
// driven through the same machine calls the turner's handlers make
// (`machine.dragChanged`/`dragEnded` + the real `JournalTurnDriver`) and the
// keyboard cycle calls the same `JournalKeyboardDismisser.resign()` the tab
// bar calls. Every cycle asserts the AC2 invariants through three independent
// channels: model state (atRest + baseTab), the ownership environment each
// page really receives, and the painted window pixels.

// MARK: - Probes

@MainActor
final class CycleLedger {
    /// Activation EVENTS the page observed (monotone; the initial mount is not
    /// an event) plus the last activation value it rendered — one tap must
    /// produce exactly one event and advance the value by exactly one.
    private(set) var bumps: [JournalTab: Int] = [:]
    private(set) var activations: [JournalTab: Int] = [:]
    private(set) var appears: [JournalTab: Int] = [:]
    private(set) var enabledNow: [JournalTab: Bool] = [:]

    func bump(_ tab: JournalTab) { bumps[tab, default: 0] += 1 }
    func note(tab: JournalTab, activation: Int, enabled: Bool) {
        activations[tab] = activation
        enabledNow[tab] = enabled
    }

    func entered(_ tab: JournalTab) { appears[tab, default: 0] += 1 }

    /// The single page that may activate content actions right now.
    var activatable: Set<JournalTab> { Set(enabledNow.filter { $0.value }.keys) }
    var mounted: Set<JournalTab> { Set(appears.keys) }
}

/// One sampled pixel, named so a three-member tuple is never needed.
struct SampleColor: Equatable {
    let red: Int
    let green: Int
    let blue: Int
}

/// Distinct synthetic grounds so the painted window names the visible page.
enum CycleGround {
    static func color(for tab: JournalTab) -> UIColor {
        switch tab {
        case .today: return UIColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1)
        case .history: return UIColor(red: 0.10, green: 0.72, blue: 0.16, alpha: 1)
        case .goals: return UIColor(red: 0.12, green: 0.18, blue: 0.88, alpha: 1)
        }
    }

    /// Distance from a sampled pixel to a declared colour, in 8-bit units.
    static func distance(_ sample: SampleColor, to color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let deltaRed = Double(sample.red) - red * 255
        let deltaGreen = Double(sample.green) - green * 255
        let deltaBlue = Double(sample.blue) - blue * 255
        return (deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue).squareRoot()
    }

    /// Nearest declared ground; the caller asserts which tab it names.
    static func nearest(_ sample: SampleColor) -> (tab: JournalTab, distance: Double) {
        var best: (tab: JournalTab, distance: Double) = (.today, .infinity)
        for tab in JournalTab.allCases {
            let distance = distance(sample, to: color(for: tab))
            if distance < best.distance { best = (tab, distance) }
        }
        return best
    }
}

/// Focus holder for the keyboard cycle: the live first-responder candidate per
/// page. Only the page that owns interaction is enabled, so the cycle must
/// focus the CURRENT tab's field (a disabled page's field refuses focus).
final class CycleFocusBox {
    var fields: [JournalTab: UITextField] = [:]

    func field(for tab: JournalTab) -> UITextField? { fields[tab] }
}

private struct CycleProbeField: UIViewRepresentable {
    let tab: JournalTab
    let box: CycleFocusBox

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "probe"
        box.fields[tab] = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
}

private struct CyclePage: View {
    let tab: JournalTab
    let activation: Int
    let ledger: CycleLedger
    let focus: CycleFocusBox?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            Color(uiColor: CycleGround.color(for: tab))
            Text(tab.title).foregroundStyle(.white)
            if let focus { CycleProbeField(tab: tab, box: focus).frame(width: 120, height: 30) }
        }
        .onAppear {
            ledger.entered(tab)
            ledger.note(tab: tab, activation: activation, enabled: isEnabled)
        }
        .onChange(of: isEnabled) { _, value in
            ledger.note(tab: tab, activation: activation, enabled: value)
        }
        .onChange(of: activation) { _, value in
            ledger.bump(tab)
            ledger.note(tab: tab, activation: value, enabled: isEnabled)
        }
    }
}

// MARK: - Shell-shaped mount

@MainActor
final class ScenePhaseBox: ObservableObject {
    @Published var phase: ScenePhase = .active
    /// What the shell actually observed (written from its `onChange`), so a
    /// test can prove a transition was delivered before flipping back.
    @Published var observed: ScenePhase = .active
}

struct CycleHost: View {
    @ObservedObject var scene: ScenePhaseBox
    @ObservedObject var presentations: JournalPresentationModel
    let viewModel: DashboardViewModel
    @ObservedObject var pager: JournalPagerModel
    let machine: JournalTurnMachine
    @ObservedObject var routeModel: JournalRouteModel
    var reduceMotion = false
    let ledger: CycleLedger
    let focus: CycleFocusBox?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if reduceMotion {
                    stage(active: pager.selection)
                        .transition(.opacity)
                        .environmentObject(machine)
                } else {
                    JournalPageTurner(pager: pager, machine: machine) { tab in stage(active: tab) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            JournalTabBar(pager: pager)
        }
        .journalPresentations(presentations, viewModel: viewModel)
        .environmentObject(viewModel)
        .environment(\.scenePhase, scene.phase)
    }

    private func stage(active: JournalTab) -> some View {
        JournalPageStage(pager: pager, active: active,
                         overlayCoversPages: routeModel.route != .tabPages) { tab, activation in
            CyclePage(tab: tab, activation: activation, ledger: ledger, focus: focus)
        }
    }
}

// MARK: - Window pixel sampling

struct WindowPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ window: UIWindow, scale: CGFloat = 0.25) {
        window.layoutIfNeeded()
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        let cgImage = image.cgImage
        let pixelWidth = cgImage?.width ?? 0
        let pixelHeight = cgImage?.height ?? 0
        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, let cgImage,
                  let context = CGContext(data: base, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        width = pixelWidth
        height = pixelHeight
        bytes = buffer
    }

    /// Row 0 is the image top (#310 orientation lesson).
    func color(column: Int, row: Int) -> SampleColor {
        let clampedColumn = max(0, min(width - 1, column))
        let clampedRow = max(0, min(height - 1, row))
        let offset = (clampedRow * width + clampedColumn) * 4
        guard offset + 2 < bytes.count else { return SampleColor(red: 0, green: 0, blue: 0) }
        return SampleColor(red: Int(bytes[offset]), green: Int(bytes[offset + 1]),
                           blue: Int(bytes[offset + 2]))
    }

    /// The ground the page area paints, sampled away from the centred label.
    func pageGround() -> (tab: JournalTab, distance: Double) {
        let samples = [SamplePoint(column: width / 8, row: height / 8),
                       SamplePoint(column: width * 7 / 8, row: height / 4),
                       SamplePoint(column: width / 8, row: height * 3 / 4)]
        var nearest: (tab: JournalTab, distance: Double) = (.today, .infinity)
        for sample in samples {
            let match = CycleGround.nearest(color(column: sample.column, row: sample.row))
            if match.distance < nearest.distance { nearest = match }
        }
        return nearest
    }
}

/// One sampling coordinate (a two-member record beats a large tuple).
struct SamplePoint {
    let column: Int
    let row: Int
}

// MARK: - Shell-shaped budget mount

/// Grounds that name which day content the REAL view model published: the
/// seeded cache (12 meals), a fresh remote answer (1 meal) or nothing yet.
enum BudgetGround {
    static let empty = UIColor(white: 0.25, alpha: 1)
    static let cached = UIColor(red: 0.10, green: 0.65, blue: 0.20, alpha: 1)
    static let fresh = UIColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1)

    static func name(_ sample: SampleColor) -> (ground: String, distance: Double) {
        let declared: [(String, UIColor)] = [("empty", empty), ("cached", cached), ("fresh", fresh)]
        var best: (ground: String, distance: Double) = ("empty", .infinity)
        for (name, color) in declared {
            let distance = CycleGround.distance(sample, to: color)
            if distance < best.distance { best = (name, distance) }
        }
        return best
    }
}

extension WindowPixels {
    /// The day-content ground the budget page paints at the page centre.
    func contentGround() -> (ground: String, distance: Double) {
        BudgetGround.name(color(column: width / 8, row: height / 8))
    }
}

struct BudgetPage: View {
    let tab: JournalTab
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        ZStack {
            ground
            Text(tab.title).foregroundStyle(.white)
        }
    }

    private var ground: Color {
        guard let snapshot = viewModel.snapshot, !snapshot.meals.isEmpty else {
            return Color(uiColor: BudgetGround.empty)
        }
        let isCachedMarker = snapshot.meals.count == ResponsivenessFixture.mealCount
        return Color(uiColor: isCachedMarker ? BudgetGround.cached : BudgetGround.fresh)
    }
}

/// Counts the pager's own selection changes: the direct "one action per tap"
/// witness on the single source of truth both the page and the tab bar read.
@MainActor
final class PagerActionCounter {
    private(set) var changes = 0
    private var cancellable: AnyCancellable?

    init(pager: JournalPagerModel) {
        cancellable = pager.$selection.dropFirst().sink { [weak self] _ in
            self?.changes += 1
        }
    }
}

/// Applies a controllable scene phase from OUTSIDE the shell, so a shell that
/// reads `@Environment(\.scenePhase)` itself really sees the change.
struct ScenePhaseHost<Content: View>: View {
    @ObservedObject var scene: ScenePhaseBox
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.scenePhase, scene.phase)
    }
}

/// The shell-shaped lifecycle mount: the REAL turner/stage/bar plus the
/// shell's exact refresh triggers (`.task`, `scenePhase`, `pager.selection`).
struct BudgetShell: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var scene: ScenePhaseBox
    @ObservedObject var pager: JournalPagerModel
    let machine: JournalTurnMachine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            JournalPageTurner(pager: pager, machine: machine) { tab in
                JournalPageStage(pager: pager, active: tab, overlayCoversPages: false) { tab, _ in
                    BudgetPage(tab: tab, viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            JournalTabBar(pager: pager)
        }
        .environmentObject(viewModel)
        .task {
            async let health: Void = viewModel.importWeights()
            await viewModel.load()
            _ = await health
        }
        .onChange(of: scenePhase) { _, phase in
            scene.observed = phase
            switch phase {
            case .active: Task { await viewModel.load() }
            case .background: viewModel.cancelRefresh()
            default: break
            }
        }
        .onChange(of: pager.selection) { oldTab, newTab in
            if oldTab == .today, newTab != .today { viewModel.cancelRefresh() }
            if oldTab != newTab, newTab == .today { Task { await viewModel.load() } }
        }
    }
}
