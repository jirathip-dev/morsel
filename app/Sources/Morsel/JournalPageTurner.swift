import Foundation
import SwiftUI

// Issue #111 — hinged journal page turn. #105 shipped the three primary tabs
// in a native page-style TabView (a flat horizontal slide); the approved V1
// prototype turns a page on a hinge: the incoming page swings in from the
// binding edge with a fade (−70° → 0°, opacity 0.2 → 1, ~0.55 s ease-out) and
// a backward turn mirrors the hinge on the trailing edge. JournalPagerModel
// stays the single source of truth: this view swings when the model's
// selection changes, and an interactive horizontal drag previews/swipes the
// adjacent page through the same JournalTabNavigation rules (never wraps at
// the first/last tab). Reduce Motion never mounts this view — the shell
// swaps pages with a plain opacity fade instead.

// MARK: - Hinge seam

/// The approved V1 turn geometry (issue #90 prototype + DESIGN.md): signed
/// start pose and hinge anchor per direction, the swing duration and its
/// cubic-bezier(.2, .7, .2, 1) curve, the start opacity, and the 3D viewer
/// distance. Pinned by JournalHingeSeamTests and the hosted
/// app/issue-111-hinged-turn-contract.test.ts probe.
enum JournalTurnSeam {
    /// Signed start angle: forward swings in from −70°; backward mirrors on
    /// the trailing hinge (+70°) so the direction reads correctly.
    static func startAngle(for direction: PageTurnDirection) -> Double {
        switch direction {
        case .forward: return -70
        case .backward: return 70
        }
    }

    /// Hinge edge of the incoming page: leading (binding) for a forward
    /// turn, trailing for a backward turn.
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

    /// 3D viewer distance for the hinge projection. The prototype writes CSS
    /// `perspective: 1400px` on its ~390px phone; SwiftUI's perspective
    /// parameter is a relative distance calibrated on-device (1400 rendered
    /// far too close; 0.7 matches the approved gentle book-page look at the
    /// 390pt screen width).
    static let perspective: CGFloat = 0.7

    /// Reduce-Motion fade duration (prototype .28s ease-out) — the shell's
    /// non-3D path shares this seam so both modes stay in lockstep.
    static let reducedDuration: Double = 0.28
}

// MARK: - Turn pose

/// Applies the swing pose to the incoming page: rotation around the hinge
/// edge from ±70° → 0° with the 0.2 → 1 fade as `progress` goes 0 → 1.
private struct HingeTurnPose: ViewModifier {
    let direction: PageTurnDirection
    let progress: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(JournalTurnSeam.startAngle(for: direction) * (1 - progress)),
                axis: (x: 0, y: 1, z: 0),
                anchor: JournalTurnSeam.anchor(for: direction),
                perspective: JournalTurnSeam.perspective
            )
            .opacity(JournalTurnSeam.startOpacity + (1 - JournalTurnSeam.startOpacity) * progress)
    }
}

/// A turn in flight: `incoming` swings from the seam's start pose toward
/// flat as `progress` goes 0 → 1. Committed turns settle on completion;
/// uncommitted turns are interactive drag previews that commit or roll back.
private struct JournalTurnState {
    let id: UUID
    let incoming: JournalTab
    let direction: PageTurnDirection
    var progress: Double
    var committed: Bool
}

// MARK: - Hinged pager

/// Custom journal pager replacing the .page TabView (issue #111). Shows the
/// settled page; while a turn is in flight the incoming page swings in above
/// it on the hinge. All moves flow through JournalPagerModel so the visible
/// page and the tab indicator cannot drift (rapid taps settle on the last
/// requested tab).
struct JournalPageTurner<Page: View>: View {
    @ObservedObject var pager: JournalPagerModel
    private let makePage: (JournalTab) -> Page

    @State private var baseTab: JournalTab
    @State private var turn: JournalTurnState?

    init(pager: JournalPagerModel, makePage: @escaping (JournalTab) -> Page) {
        self.pager = pager
        self.makePage = makePage
        _baseTab = State(initialValue: pager.selection)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                makePage(baseTab)
                if let turn {
                    makePage(turn.incoming)
                        .id(turn.id) // new identity per turn: retargets re-insert
                        .modifier(HingeTurnPose(direction: turn.direction, progress: turn.progress))
                        .zIndex(1)
                        .onAppear { startProgrammaticSwing(turn.id) }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(turnGesture(width: proxy.size.width))
        }
        .clipped()
        .onChange(of: pager.selection) { oldTab, newTab in
            selectionChanged(from: oldTab, to: newTab)
        }
    }
}

// MARK: - Turn driving

private extension JournalPageTurner {
    func turnGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 15, coordinateSpace: .local)
            .onChanged { value in updateDrag(value, width: width) }
            .onEnded { value in finishDrag(value, width: width) }
    }

    /// Interactive drag preview: only horizontal intent engages, and only
    /// when an adjacent page exists (no-wrap boundaries preview nothing).
    func updateDrag(_ value: DragGesture.Value, width: CGFloat) {
        if let active = turn, active.committed {
            return // a committed swing already owns the stage
        }
        let deltaX = value.translation.width
        let deltaY = value.translation.height
        guard abs(deltaX) > abs(deltaY) else {
            return // vertical page scrolls stay vertical — never stolen
        }
        let direction: PageTurnDirection = deltaX < 0 ? .forward : .backward
        let progress = min(abs(deltaX) / max(width, 1), 1)
        guard let adjacent = JournalTabNavigation.adjacent(to: baseTab, turning: direction) else {
            turn = nil // boundary drag (or a reversal into one) previews nothing
            return
        }
        if let active = turn, active.incoming == adjacent, active.direction == direction {
            var updated = active
            updated.progress = progress
            turn = updated
        } else {
            turn = JournalTurnState(
                id: UUID(),
                incoming: adjacent,
                direction: direction,
                progress: progress,
                committed: false
            )
        }
    }

    /// Drag end: half a page dragged or a fast flick commits through the
    /// model; anything else rolls the preview back to the start pose.
    func finishDrag(_ value: DragGesture.Value, width: CGFloat) {
        guard let active = turn, !active.committed else { return }
        let distance = abs(value.translation.width)
        guard distance > 0 else {
            turn = nil
            return
        }
        let predicted = abs(value.predictedEndTranslation.width)
        let commits = predicted >= width / 2 || distance >= width / 2
        if commits {
            var updated = active
            updated.committed = true
            turn = updated
            pager.swipe(active.direction) // single source of truth + tab sync
            let remaining = JournalTurnSeam.richDuration * (1 - active.progress)
            swing(progress: 1, duration: remaining, turnID: active.id, settleAfter: remaining)
        } else {
            let remaining = JournalTurnSeam.richDuration * active.progress
            swing(progress: 0, duration: remaining, turnID: active.id, settleAfter: remaining)
        }
    }

    /// Tab-bar taps / external selects: swing from the settled page to the
    /// requested one. The model already holds the target selection.
    func selectionChanged(from oldTab: JournalTab, to newTab: JournalTab) {
        guard oldTab != newTab else { return }
        if let active = turn {
            if active.committed {
                if newTab == active.incoming {
                    return // our own drag-commit echo; the settle is running
                }
                // Retarget mid-swing: settle the incoming instantly, then
                // hinge the rest of the way to the newest request.
                baseTab = active.incoming
                turn = nil
                startSwing(from: active.incoming, to: newTab)
                return
            }
            turn = nil // an uncommitted drag preview yields to the tap
        }
        guard newTab != baseTab else { return }
        startSwing(from: baseTab, to: newTab)
    }

    /// Insert a committed swing at the start pose; onAppear animates it.
    func startSwing(from outgoing: JournalTab, to incoming: JournalTab) {
        guard let direction = JournalTabNavigation.direction(from: outgoing, to: incoming) else {
            return
        }
        turn = JournalTurnState(
            id: UUID(),
            incoming: incoming,
            direction: direction,
            progress: 0,
            committed: true
        )
    }

    /// First render of a committed swing: animate 0 → 1 with the seam curve.
    func startProgrammaticSwing(_ turnID: UUID) {
        guard let active = turn, active.id == turnID, active.committed, active.progress == 0 else {
            return
        }
        swing(
            progress: 1,
            duration: JournalTurnSeam.richDuration,
            turnID: turnID,
            settleAfter: JournalTurnSeam.richDuration
        )
    }

    func swing(progress: Double, duration: Double, turnID: UUID, settleAfter: Double) {
        withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: duration)) {
            turn?.progress = progress
        }
        settle(after: settleAfter, turnID: turnID)
    }

    /// After the swing ends: promote the incoming page to the base (committed
    /// turns) or just drop the preview (rollbacks). A stale task for a turn
    /// that was retargeted in the meantime does nothing.
    func settle(after delay: Double, turnID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let active = turn, active.id == turnID else { return }
            if active.committed {
                baseTab = active.incoming
            }
            turn = nil
        }
    }
}
