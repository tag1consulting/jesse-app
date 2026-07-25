import XCTest
import AppKit
@testable import Jesse_Mac

/// The composer's Return-key contract, exhaustively. This is the whole behavioral rule of the
/// fix: Return sends, Return with any modifier makes a newline, a live input method composition
/// owns the key. It is a pure function precisely so this table can exist: the old composer put
/// the decision in SwiftUI's `.onSubmit`, which is handed no modifier state, so no test at any
/// layer could have distinguished Return from Shift plus Return.
final class ComposerKeyActionTests: XCTestCase {

    private let ret = ComposerKeyCode.return
    private let enter = ComposerKeyCode.keypadEnter

    /// Key codes that are not Return: A, Tab, Space, Delete, Escape, Up arrow, keypad 0.
    private let otherKeyCodes: [UInt16] = [0, 48, 49, 51, 53, 126, 82]

    // MARK: - The table

    func testTheFullDecisionTable() {
        // (label, keyCode, modifiers, hasMarkedText, expected)
        let cases: [(String, UInt16, NSEvent.ModifierFlags, Bool, ComposerKeyAction)] = [
            // Plain Return and plain keypad Enter send.
            ("Return", ret, [], false, .send),
            ("keypad Enter", enter, [], false, .send),

            // Each modifier alone makes a newline.
            ("Shift+Return", ret, .shift, false, .insertNewline),
            ("Control+Return", ret, .control, false, .insertNewline),
            ("Option+Return", ret, .option, false, .insertNewline),
            ("Command+Return", ret, .command, false, .insertNewline),
            ("Shift+keypad Enter", enter, .shift, false, .insertNewline),
            ("Control+keypad Enter", enter, .control, false, .insertNewline),
            ("Option+keypad Enter", enter, .option, false, .insertNewline),
            ("Command+keypad Enter", enter, .command, false, .insertNewline),

            // Combinations: still a newline, never a send.
            ("Shift+Command+Return", ret, [.shift, .command], false, .insertNewline),
            ("Control+Option+Return", ret, [.control, .option], false, .insertNewline),
            ("all four + Return", ret, [.shift, .control, .option, .command], false, .insertNewline),

            // Flags that are NOT a user holding a modifier down. Keypad Enter arrives with
            // `.function` and `.numericPad` set; caps lock is a latch, not a held modifier.
            // Reading any of these as a modifier would break the keypad Enter send.
            ("keypad Enter (.function+.numericPad)", enter, [.function, .numericPad], false, .send),
            ("Return (.function)", ret, .function, false, .send),
            ("Return (.numericPad)", ret, .numericPad, false, .send),
            ("Return (.capsLock)", ret, .capsLock, false, .send),
            ("keypad Enter (.capsLock+.numericPad)", enter, [.capsLock, .numericPad], false, .send),
            // A real modifier alongside the keypad's own flags is still a newline.
            ("Shift+keypad Enter (+pad flags)", enter, [.shift, .function, .numericPad], false,
             .insertNewline),

            // A live composition (IME, dead key, accent popover) commits with Return. Never a
            // send, and not our newline either: the text system gets the key.
            ("Return while composing", ret, [], true, .passThrough),
            ("keypad Enter while composing", enter, [], true, .passThrough),
            ("Shift+Return while composing", ret, .shift, true, .passThrough),
            ("Command+Return while composing", ret, .command, true, .passThrough),
        ]

        for (label, keyCode, modifiers, marked, expected) in cases {
            let actual = composerKeyAction(keyCode: keyCode, modifiers: modifiers,
                                           hasMarkedText: marked)
            XCTAssertEqual(actual, expected, "\(label) should be \(expected), got \(actual)")
        }
    }

    func testEveryNonReturnKeyPassesThroughWhateverIsHeld() {
        let modifierSets: [NSEvent.ModifierFlags] = [
            [], .shift, .control, .option, .command, [.shift, .command],
            [.function, .numericPad], .capsLock,
        ]
        for keyCode in otherKeyCodes {
            for modifiers in modifierSets {
                for marked in [false, true] {
                    XCTAssertEqual(
                        composerKeyAction(keyCode: keyCode, modifiers: modifiers,
                                          hasMarkedText: marked),
                        .passThrough,
                        "key code \(keyCode) is not Return and must pass through")
                }
            }
        }
    }

    /// The exact key codes, pinned. A wrong constant here is a composer that never sends.
    func testKeyCodeConstants() {
        XCTAssertEqual(ComposerKeyCode.return, 36, "kVK_Return")
        XCTAssertEqual(ComposerKeyCode.keypadEnter, 76, "kVK_ANSI_KeypadEnter")
    }

    /// Modifier flags arrive with hardware-specific bits set (left vs right Shift, and other
    /// device-dependent state). The function reduces with `deviceIndependentFlagsMask`, so a raw
    /// event still decides the same way.
    func testRawDeviceDependentFlagsDoNotChangeTheDecision() {
        // Left shift as AppKit reports it on a real key press: `.shift` plus a device bit.
        let rawLeftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
        XCTAssertEqual(composerKeyAction(keyCode: ret, modifiers: rawLeftShift, hasMarkedText: false),
                       .insertNewline)
        // A device bit with NO real modifier still sends.
        let rawNoModifier = NSEvent.ModifierFlags(rawValue: 0x1)
        XCTAssertEqual(composerKeyAction(keyCode: ret, modifiers: rawNoModifier, hasMarkedText: false),
                       .send)
    }
}
