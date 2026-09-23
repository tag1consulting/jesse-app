import Foundation

// THE SAME MEASUREMENT, ON THE DEVICE IT ACTUALLY MATTERS ON.
//
// The reader's performance budget was measured on a Mac, because that is where the branch
// was written. The reader runs on a phone. Those are different machines and the gap
// between them is exactly the thing a number written in a pull request cannot tell you, so
// the measurement is a BUTTON on the diagnostics screen as well as a test: same fixture
// rule (the largest note in the folder), same two operations, same medians, readable on
// the phone in the hand.
//
// Median rather than mean, and warm-ups discarded, for the reason every benchmark does it:
// the first parse in a process pays for lazily-built Foundation state that no later parse
// pays for, and one scheduling hiccup should not become the headline number.

/// What one run of the benchmark measured.
public struct VaultRenderBenchmarkReport: Equatable, Sendable {
    public let path: String
    public let bytes: Int
    public let lines: Int
    public let blocks: Int
    public let iterations: Int
    /// Milliseconds.
    public let parseMedian: Double
    public let renderMedian: Double

    public init(path: String, bytes: Int, lines: Int, blocks: Int, iterations: Int,
                parseMedian: Double, renderMedian: Double) {
        self.path = path
        self.bytes = bytes
        self.lines = lines
        self.blocks = blocks
        self.iterations = iterations
        self.parseMedian = parseMedian
        self.renderMedian = renderMedian
    }

    /// The screen's rows. Selectable text, like every other number on that screen, so a
    /// measurement can leave the phone as text rather than as a recollection.
    public var displayLines: [String] {
        [
            "Note: \(path)",
            "Size: \(bytes) bytes, \(lines) lines, \(blocks) blocks",
            String(format: "Parse:  %.2f ms (median of %d)", parseMedian, iterations),
            String(format: "Render: %.2f ms (median of %d)", renderMedian, iterations),
        ]
    }
}

public enum VaultRenderBenchmark {

    public static let defaultWarmups = 3
    public static let defaultIterations = 20

    /// Parse `text` and render every one of its blocks, repeatedly, and report the medians.
    ///
    /// Pure and synchronous. The caller decides which actor it runs on, and every caller
    /// in this target runs it OFF the main one: it is deliberately seconds of work.
    public static func run(path: String, text: String,
                           warmups: Int = defaultWarmups,
                           iterations: Int = defaultIterations) -> VaultRenderBenchmarkReport {
        var parseSamples: [Double] = []
        for i in 0..<(warmups + iterations) {
            let started = ContinuousClock.now
            _ = VaultNoteDocument.parse(path: path, text: text)
            let elapsed = ContinuousClock.now - started
            if i >= warmups { parseSamples.append(milliseconds(elapsed)) }
        }

        let document = VaultNoteDocument.parse(path: path, text: text)
        // Every target resolved, so the render pass does the EXPENSIVE thing (building a
        // link) rather than the cheap one for each link it meets.
        var resolved: [String: String] = [:]
        for target in document.wikiTargets { resolved[target] = target + ".md" }

        var renderSamples: [Double] = []
        for i in 0..<(warmups + iterations) {
            let started = ContinuousClock.now
            for block in document.blocks {
                for piece in block.inlineTexts {
                    _ = VaultNoteRenderer.attributed(piece, resolved: resolved)
                }
            }
            let elapsed = ContinuousClock.now - started
            if i >= warmups { renderSamples.append(milliseconds(elapsed)) }
        }

        return VaultRenderBenchmarkReport(
            path: path,
            bytes: text.utf8.count,
            lines: document.rawLines.count,
            blocks: document.blocks.count,
            iterations: iterations,
            parseMedian: median(parseSamples),
            renderMedian: median(renderSamples))
    }

    public static func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    public static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
