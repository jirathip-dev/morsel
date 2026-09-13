import Combine
import Foundation
import SwiftUI

// Issue #111 — hinged journal page turn: the incoming page swings in on the
// approved V1 hinge (−70° → 0° with an 0.2 → 1 fade over ~0.55 s, mirrored to
// the trailing edge for a backward turn). JournalPagerModel stays the single
// source of truth (tab taps settle on the last requested tab; drags preview
// the adjacent page through JournalTabNavigation and never wrap). Reduce
// Motion never mounts this view — the shell swaps pages with a plain fade.
//
// Issue #174 — the turn is an explicit state machine (idle / dragging /
// committing / rollingBack) with drag axis ownership and cancellation: every
// new gesture or animation operation invalidates previous completions, a
// vertical intent change clears any live preview, and scene inactivity /
// removal interrupts the turn so exactly one page is settled at rest.
// Issue #175 — the turner renders the retained page stage: ONE page per
// visited tab, so a preview can neither replace a model nor start a read.

// MARK: - Hinge seam

/// The approved V1 turn geometry (issue #90 prototype + DESIGN.md), pinned by
/// JournalHingeSeamTests and app/issue-111-hinged-turn-contract.test.ts.
enum JournalTurnSeam {
    /// Signed start angle: forward swings in from −70°, backward mirrors (+70°).
    static func startAngle(for direction: PageTurnDirection) -> Double {
        switch direction {
        case .forward: return -70
        case .backward: return 70
        }
    }

    /// Hinge edge of the incoming page: leading (binding) forward, trailing back.
    static func anchor(for direction: PageTurnDirection) -> UnitPoint {
        switch direction {
        case .forward: return .leading
        case .backward: return .trailing
        }
    }

    /// Opacity of the incoming page at the start of the swing.
    static let startOpacity: Double = 0.2

    /// Full swing duration (prototype .55s).
    static let richDuration: Double = 0.55

    /// SwiftUI's equivalent of the prototype cubic-bezier(.2, .7, .2, 1).
    static var richAnimation: Animation {
        .timingCurve(0.2, 0.7, 0.2, 1, duration: richDuration)
    }

    /// 3D viewer distance (prototype CSS 1400px → on-device-calibrated 0.7).
    static let perspective: CGFloat = 0.7

    /// Reduce-Motion fade duration (prototype .28s) — shared with the shell.
    static let reducedDuration: Double = 0.28
}

// MARK: - Turn pose

/// Applies the swing pose: hinge rotation ±70° → 0° with the 0.2 → 1 fade. A
/// page that is not the live incoming sheet stays flat and hidden (#175).
struct HingeTurnPose: ViewModifier {
    let direction: PageTurnDirection
    let progress: Double
    var isIncoming = true
    var isActive = true

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(JournalTurnSeam.startAngle(for: direction) * (1 - progress) * (isIncoming ? 1 : 0)),
                axis: (x: 0, y: 1, z: 0),
                anchor: JournalTurnSeam.anchor(for: direction),
                perspective: JournalTurnSeam.perspective
            )
            .opacity(isIncoming
                ? JournalTurnSeam.startOpacity + (1 - JournalTurnSeam.startOpacity) * progress
                : (isActive ? 1 : 0))
    }
}

// MARK: - Turn state machine

/// How a finished turn settles: promote the incoming page, or drop the preview.
enum JournalTurnCompletion: Equatable {
    case promote
    case drop
}

/// Issue #174 — the pager's explicit turn state machine: the phases are
/// explicit, the drag gesture owns one axis, and every operation carries a
/// monotonic token honoured only while it is current (the audited #111 shape
/// let a stale completion mutate newer state).
final class JournalTurnMachine: ObservableObject {
    enum Phase: Equatable {
        case idle, dragging, committing, rollingBack
    }
    /// Axis ownership for one drag gesture: decided by the first update, then
    /// locked, so a gesture that began vertically never turns a page.
    enum Axis: Equatable {
        case horizontal, vertical
    }

    /// A turn in flight: `incoming` swings from the seam's start pose flat.
    struct Turn: Equatable {
        let id: UUID
        let incoming: JournalTab
        let direction: PageTurnDirection
        var progress: Double
        var committed: Bool
    }

    /// What the view must do when a drag ends or a committed swing appears:
    /// animate `progress` toward `targetProgress`, then complete `operation`.
    struct Effect: Equatable {
        let operation: UInt
        let targetProgress: Double
        let duration: Double
        let completion: JournalTurnCompletion
        /// A drag commit pivots JournalPagerModel through the previewed
        /// direction (single source of truth + tab sync).
        let swipesModel: Bool
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var baseTab: JournalTab
    @Published private(set) var turn: Turn?
    /// Monotonic operation token: every new gesture/animation operation bumps
    /// it, which invalidates all previous completions.
    private(set) var operation: UInt = 0
    private var axis: Axis?

    init(base: JournalTab = .today) {
        baseTab = base
    }

    /// Exactly one page is settled at rest: no preview, no swing in flight.
    var atRest: Bool { phase == .idle && turn == nil }

    /// One drag update: the first decides the axis, vertical ownership clears
    /// any live preview and is kept for the rest of the gesture.
    func dragChanged(deltaX: Double, deltaY: Double, width: CGFloat) {
        if case .committing = phase {
            return // a committed swing already owns the stage
        }
        if axis == .vertical {
            dropPreview()
            return
        }
        if abs(deltaX) > abs(deltaY) {
            axis = .horizontal
        } else {
            axis = .vertical
            dropPreview()
            return
        }
        let direction: PageTurnDirection = deltaX < 0 ? .forward : .backward
        let progress = min(abs(deltaX) / max(Double(width), 1), 1)
        guard let adjacent = JournalTabNavigation.adjacent(to: baseTab, turning: direction) else {
            dropPreview() // boundary drag (or a reversal into one) previews nothing
            return
        }
        if case .dragging = phase, let active = turn,
           active.incoming == adjacent, active.direction == direction {
            var updated = active
            updated.progress = progress
            turn = updated
        } else {
            // A fresh turn identity: never reuse a turn that is already
            // animating, so its completion cannot clear or settle this one.
            turn = Turn(id: UUID(), incoming: adjacent, direction: direction,
                        progress: progress, committed: false)
            phase = .dragging
            beginOperation()
        }
    }

    /// Drag end: half a page dragged or a fast flick commits, anything else
    /// rolls back. A stale end (no preview in flight) is a no-op.
    func dragEnded(deltaX: Double, predictedX: Double, width: CGFloat) -> Effect? {
        axis = nil
        guard case .dragging = phase, let active = turn else { return nil }
        let distance = abs(deltaX)
        guard distance > 0 else {
            dropPreview()
            return nil
        }
        let travel = max(Double(width), 1)
        if abs(predictedX) >= travel / 2 || distance >= travel / 2 {
            turn = Turn(id: active.id, incoming: active.incoming, direction: active.direction,
                        progress: active.progress, committed: true)
            phase = .committing
            beginOperation()
            return Effect(operation: operation, targetProgress: 1,
                          duration: JournalTurnSeam.richDuration * (1 - active.progress),
                          completion: .promote, swipesModel: true)
        }
        phase = .rollingBack
        beginOperation()
        return Effect(operation: operation, targetProgress: 0,
                      duration: JournalTurnSeam.richDuration * active.progress,
                      completion: .drop, swipesModel: false)
    }

    /// Tab taps / external selects. The echo of our own drag commit leaves the
    /// running swing alone; anything else settles or drops what is in flight.
    func selectionChanged(to newTab: JournalTab) {
        switch phase {
        case .committing:
            guard let active = turn else {
                phase = .idle
                return
            }
            if newTab == active.incoming {
                return // our own drag-commit echo; the settle is running
            }
            // Retarget mid-swing: settle the incoming instantly, then hinge
            // the rest of the way to the newest request.
            baseTab = active.incoming
            turn = nil
            phase = .idle
            beginOperation()
        case .dragging, .rollingBack:
            turn = nil // an uncommitted preview yields to the tap
            phase = .idle
            beginOperation()
        case .idle:
            break
        }
        guard newTab != baseTab,
              let direction = JournalTabNavigation.direction(from: baseTab, to: newTab) else {
            return
        }
        turn = Turn(id: UUID(), incoming: newTab, direction: direction, progress: 0, committed: true)
        phase = .committing
        beginOperation()
    }

    /// First render of a committed swing: animate 0 → 1 with the seam curve.
    func swingDidAppear(id: UUID) -> Effect? {
        guard case .committing = phase, let active = turn,
              active.id == id, active.progress == 0 else {
            return nil
        }
        return Effect(operation: operation, targetProgress: 1, duration: JournalTurnSeam.richDuration,
                      completion: .promote, swipesModel: false)
    }

    /// Apply an effect's pose change — the driver wraps this in withAnimation.
    func apply(_ effect: Effect) {
        guard effect.operation == operation else { return }
        turn?.progress = effect.targetProgress
    }

    /// Controllable completion: honoured only while its operation is current.
    @discardableResult
    func complete(operation completedOperation: UInt) -> Bool {
        guard completedOperation == operation else { return false }
        switch phase {
        case .committing:
            if let active = turn {
                baseTab = active.incoming
            }
        case .rollingBack:
            break
        case .idle, .dragging:
            return false
        }
        turn = nil
        phase = .idle
        return true
    }

    /// Scene inactivity / presentation interruption: settle one page now (a
    /// commit lands on its destination), leaving no preview.
    func interrupt() {
        axis = nil
        switch phase {
        case .committing:
            if let active = turn {
                baseTab = active.incoming
            }
        case .dragging, .rollingBack:
            break
        case .idle:
            return
        }
        turn = nil
        phase = .idle
        beginOperation()
    }

    private func dropPreview() {
        guard turn != nil else { return }
        turn = nil
        phase = .idle
        beginOperation()
    }

    private func beginOperation() {
        operation &+= 1
    }
}

// MARK: - Turn driving

/// Applies turn effects to the pager/model pair: pivots the model on a drag
/// commit, animates the pose change, completes the swing when it ends.
@MainActor
struct JournalTurnDriver {
    let pager: JournalPagerModel
    let machine: JournalTurnMachine

    func run(_ effect: JournalTurnMachine.Effect?) {
        guard let effect else { return }
        if effect.swipesModel, let active = machine.turn {
            pager.swipe(active.direction)
        }
        withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: effect.duration)) {
            machine.apply(effect)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(effect.duration))
            machine.complete(operation: effect.operation)
        }
    }
}

// MARK: - Hinged pager

/// Custom journal pager replacing the .page TabView (issue #111): it renders
/// the retained page stage (#175) the turn machine poses through the
/// environment, so the visible page and the tab indicator cannot drift.
struct JournalPageTurner<Page: View>: View {
    @ObservedObject var pager: JournalPagerModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var machine: JournalTurnMachine
    private let makePage: (JournalTab) -> Page

    init(pager: JournalPagerModel, makePage: @escaping (JournalTab) -> Page) {
        self.init(pager: pager, machine: JournalTurnMachine(base: pager.selection), makePage: makePage)
    }

    /// Mounted-race seam (#174): the suites drive the machine exactly like the gesture.
    init(pager: JournalPagerModel, machine: JournalTurnMachine,
         makePage: @escaping (JournalTab) -> Page) {
        self.pager = pager
        self.makePage = makePage
        _machine = StateObject(wrappedValue: machine)
    }

    var body: some View {
        GeometryReader { proxy in
            makePage(machine.baseTab)
                .environmentObject(machine) // the stage poses the live turn
                .contentShape(Rectangle())
                .simultaneousGesture(turnGesture(width: proxy.size.width))
        }
        .clipped()
        .onChange(of: pager.selection) { _, newTab in
            machine.selectionChanged(to: newTab)
        }
        .onChange(of: machine.turn?.id) { _, _ in
            // A fresh committed swing (tab tap / retarget) animates in; a
            // preview at drag progress is left alone by swingDidAppear.
            if let turn = machine.turn {
                driver.run(machine.swingDidAppear(id: turn.id))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                machine.interrupt() // scene inactivity: settle one page
            }
        }
        .onDisappear { machine.interrupt() } // presentation interruption
    }

    private var driver: JournalTurnDriver {
        JournalTurnDriver(pager: pager, machine: machine)
    }

    private func turnGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 15, coordinateSpace: .local)
            .onChanged { value in updateDrag(value, width: width) }
            .onEnded { value in finishDrag(value, width: width) }
    }

    func updateDrag(_ value: DragGesture.Value, width: CGFloat) {
        machine.dragChanged(deltaX: value.translation.width,
                            deltaY: value.translation.height,
                            width: width)
    }

    func finishDrag(_ value: DragGesture.Value, width: CGFloat) {
        driver.run(machine.dragEnded(deltaX: value.translation.width,
                                     predictedX: value.predictedEndTranslation.width,
                                     width: width))
    }
}
