import SwiftUI
import UIKit

// Issue #105 — shared keyboard/focus-dismissal contract (AC6): Add Meal,
// Edit Item, Goals, and email/code sign-in all follow the same rules —
// tapping blank page space or a non-input control clears focus, vertical
// scrolling dismisses the keyboard, numeric fields expose a visible Done
// action (their pads have no Return key), and interactive controls stay
// tappable. Rules are classified here so native tests and every surface
// share one policy table.

/// What a journal field types. Numeric fields need the shared Done bar;
/// text/multiline fields keep the default keyboard and its Return key.
enum JournalInputKind: Equatable, Sendable {
    case text
    case numeric
    case multiline

    /// Visible-Done policy: numeric pads (no Return) always expose Done.
    var needsVisibleDone: Bool { self == .numeric }
}

enum JournalKeyboardKind {
    /// Classify any UIKeyboardType the journal surfaces use.
    static func classify(keyboardType: UIKeyboardType) -> JournalInputKind {
        switch keyboardType {
        case .decimalPad, .numberPad, .numbersAndPunctuation:
            return .numeric
        default:
            return .text
        }
    }

    /// True when a focused field with this keyboard needs the Done bar.
    static func needsVisibleDone(keyboardType: UIKeyboardType) -> Bool {
        classify(keyboardType: keyboardType).needsVisibleDone
    }
}

/// Shared first-responder resignation seam: resigns whatever text field owns
/// the keyboard anywhere in the window. Used by blank-space taps, picker /
/// date / tab / non-input control taps, and page actions while the keyboard
/// is open.
enum JournalKeyboardDismisser {
    @MainActor
    static func resign() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension View {
    /// Clears text-field focus when this (non-input) control is activated —
    /// pickers, date pickers, chips, and toolbar actions. Attach to the row
    /// or control; the control's own activation still proceeds.
    func morselResignsKeyboardOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded {
            JournalKeyboardDismisser.resign()
        })
    }

    /// Blank-page-space dismissal: wraps content in a clear under-layer that
    /// receives taps only where no control or gesture view sits on top, so
    /// tapping empty paper clears focus while fields, buttons, and pickers
    /// keep their own taps (AC6). Inside the scroll content this never
    /// competes with scrolling or page swipes (tap only, no drag claim).
    func morselBlankSpaceDismissesKeyboard() -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    JournalKeyboardDismisser.resign()
                }
            self
        }
    }

    /// Shared visible-Done bar for numeric fields (AC6): while the focused
    /// field's keyboard is a numeric pad, a Done item sits above the keyboard
    /// and clears focus. `keyboardType` maps the active focus key to the
    /// keyboard it opened.
    func morselNumericDoneBar<Key: Hashable>(
        focused: FocusState<Key?>.Binding,
        keyboardType: @escaping (Key) -> UIKeyboardType
    ) -> some View {
        toolbar {
            if let activeKey = focused.wrappedValue,
               JournalKeyboardKind.needsVisibleDone(keyboardType: keyboardType(activeKey)) {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focused.wrappedValue = nil
                    }
                }
            }
        }
    }
}
