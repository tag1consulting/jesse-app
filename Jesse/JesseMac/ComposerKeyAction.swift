import AppKit

// The composer's Return-key contract, as one pure function.
//
// The whole point of this file is that the decision is separable from the view. The old
// composer was a SwiftUI `TextField(axis: .vertical)` whose send hung off `.onSubmit`, and
// `.onSubmit` is handed NO modifier state: by the time it fires, whether Shift was down is
// already lost. So there was no place to put this rule at all, which is why every Return
// variant collapsed into "send" and why no unit test could have caught it. Now the rule lives
// here, in a function with no UI in it, and the view is the thin part.

// `nonisolated` throughout: the target compiles with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// and a pure decision over two value types has no business being pinned to an actor. It also
// keeps the rule usable (and testable) from anywhere.

/// What a key press in the composer should do.
nonisolated enum ComposerKeyAction: Equatable {
    /// Send the current draft as a turn (subject to the send gate, which lives elsewhere).
    case send
    /// Insert a literal newline at the caret and do not send.
    case insertNewline
    /// Not our business: let the text system handle the key normally.
    case passThrough
}

/// The two key codes that mean "Return" on a Mac keyboard (`kVK_Return` and
/// `kVK_ANSI_KeypadEnter`). Named rather than inlined so the tests and the view agree.
nonisolated enum ComposerKeyCode {
    static let `return`: UInt16 = 36
    static let keypadEnter: UInt16 = 76
}

/// Decide what a composer key press means.
///
/// - Plain Return (and plain keypad Enter) sends.
/// - Return with ANY of Shift, Control, Option, or Command held inserts a newline.
/// - Return during an input method composition passes through, so the Return commits the
///   composition (Japanese/Chinese IME, a dead key, accent popover) instead of firing a turn
///   with half-typed text.
/// - Everything else passes through untouched.
///
/// - Parameters:
///   - keyCode: the event's hardware key code (`NSEvent.keyCode`).
///   - modifiers: the event's modifier flags (`NSEvent.modifierFlags`), raw.
///   - hasMarkedText: whether the text view currently holds marked (uncommitted) text.
nonisolated func composerKeyAction(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    hasMarkedText: Bool
) -> ComposerKeyAction {
    guard keyCode == ComposerKeyCode.return || keyCode == ComposerKeyCode.keypadEnter else {
        return .passThrough
    }
    // A live composition owns the Return key. Committing beats sending, always.
    if hasMarkedText { return .passThrough }
    // Only the four real modifier keys count. The raw flags also carry state that is NOT a
    // user holding a key down: keypad Enter arrives with `.function` and `.numericPad` set,
    // and caps lock shows up as `.capsLock`. Reading any of those as "a modifier is held"
    // would make keypad Enter insert a newline instead of sending.
    let held = modifiers.intersection(.deviceIndependentFlagsMask)
    let newlineModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    return held.intersection(newlineModifiers).isEmpty ? .send : .insertNewline
}
