import XCTest
@testable import JesseVault
#if os(macOS)
import AppKit
#endif

// THE KEYSTROKE BUDGET, MEASURED RATHER THAN ASSERTED.
//
// "The editor must not be laggy" is worth exactly what its measurement is worth, and the
// measurement that matters is the one on the biggest note the reader will open: 250 KB in
// one text view, then one character typed into the MIDDLE of it, which is the expensive
// case (typing at the end can be laid out incrementally; typing in the middle cannot
// always be).
//
// WHAT IS TIMED is the whole per-keystroke round trip the app actually performs: the
// delegate's `shouldChangeText`, the insertion, `didChangeText` — which is what pushes the
// new string back into the model's binding, and therefore the expensive part, because it
// copies the document — and then forcing layout, so the number includes the work that
// would otherwise happen on the next frame and be invisible to a naive timer.
//
// It is a timestamp measurement, not Instruments. That is a deliberate trade: it runs in
// CI-adjacent form on any machine, unattended, on both sides of a change, where an
// Instruments trace is a thing one person did once on one laptop.
//
// macOS only, because that is where the number was asked for. The iOS path is the same
// shape through `UITextView` and is not measurable without a simulator host.
final class VaultEditorLatencyTests: XCTestCase {

    #if os(macOS)

    /// Five warm-ups then twenty measured, median reported — the same discipline the
    /// render benchmark uses and for the same reason.
    static let warmups = 5
    static let iterations = 20

    /// The budget this prompt is written against.
    static let budgetMilliseconds = 50.0

    @MainActor
    func testKeystrokeLatencyOnA250KBNote() throws {
        let note = Self.syntheticNote()
        XCTAssertGreaterThan(note.utf8.count, 200 * 1024, "the fixture must be the size we claim")

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.string = note
        Self.forceLayout(view)

        // The middle of the document, which is the case a naive "type at the end" test
        // would flatter.
        let middle = note.utf16.count / 2
        var samples: [Double] = []

        for i in 0..<(Self.warmups + Self.iterations) {
            let at = NSRange(location: middle + i, length: 0)
            let started = ContinuousClock.now

            // The real per-keystroke round trip.
            if view.shouldChangeText(in: at, replacementString: "x") {
                view.textStorage?.replaceCharacters(in: at, with: "x")
                view.didChangeText()
            }
            // The part that would otherwise land on the next frame.
            _ = view.string.utf8.count
            Self.forceLayout(view)

            let elapsed = VaultRenderBenchmark.milliseconds(ContinuousClock.now - started)
            if i >= Self.warmups { samples.append(elapsed) }
        }

        let median = VaultRenderBenchmark.median(samples)
        print("""

            === VAULT EDITOR KEYSTROKE LATENCY (NSTextView, macOS) ===
            document:        \(note.utf8.count) bytes
            keystrokes:      \(samples.count) measured after \(Self.warmups) warm-ups
            insertion point: middle of the document
            median:          \(String(format: "%.3f", median)) ms
            range:           \(String(format: "%.3f", samples.min() ?? 0)) .. \
            \(String(format: "%.3f", samples.max() ?? 0)) ms
            budget:          \(Self.budgetMilliseconds) ms
            ==========================================================

            """)

        XCTAssertLessThan(median, Self.budgetMilliseconds,
                          "a laggy editor is worse than no editor")
    }

    /// Lay the document out for real, through whichever TextKit the view is using.
    static func forceLayout(_ view: NSTextView) {
        if let layout = view.textLayoutManager, let content = layout.textContentManager {
            layout.ensureLayout(for: content.documentRange)
        } else if let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
        }
    }

    /// The same shape of note the render benchmark uses, and invented for the same reason:
    /// this repository is public and no line of a real note belongs in it.
    static func syntheticNote() -> String {
        var out = "---\ntitle: The Long Bench Note\n---\n\n"
        var section = 0
        while out.utf8.count < 250 * 1024 {
            section += 1
            out += """
                # Firing \(section)

                The floor of the chamber cracked along the back seam again, and the crack \
                runs further than it did in the spring. Measured cold it is about four \
                millimetres at the widest point, narrowing to nothing under the bag wall.

                - soft brick, grade 26, from [[Suppliers/Terrasole]]
                - [ ] order the anchors
                - [x] measure the arch

                > The yard is closed for the whole of August.

                ```swift
                let ramp = Ramp(perHour: 60, hold: .minutes(20))
                ```

                ---


                """
        }
        return out
    }

    #endif
}
