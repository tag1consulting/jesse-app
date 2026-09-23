import XCTest
@testable import JesseVault

// THE BUDGET, AS A NUMBER.
//
// "The reader must not get slower" is a claim, and a claim about a parser is worth what
// its measurement is worth. This file is that measurement: one synthetic note of about
// 250 KB built from every construct the vault actually uses, parsed and rendered a fixed
// number of times, reported as a MEDIAN rather than a mean so one scheduling hiccup on a
// laptop that is also compiling something does not become the headline number.
//
// It is a TEST rather than a script for one reason: it has to be runnable, unchanged, on
// both sides of the change. The fixture generator below is deliberately self-contained —
// it calls nothing but `String` — so this same file measures the old block model and the
// new one and the two numbers mean the same thing.
//
// The fixture is INVENTED. This repository is public and no line of a real note belongs
// in it; the note below is a pottery workshop that does not exist.
//
// It asserts almost nothing (a parse that returns no blocks is a broken benchmark, and
// that is worth catching) — its output is the point, and it prints it.
final class VaultNoteBenchmarkTests: XCTestCase {

    /// 3 warm-ups then 20 measured iterations, median reported. The warm-ups exist because
    /// the first parse of a process pays for lazily-built Foundation state that no later
    /// parse pays for, and folding that into the number would flatter whichever side ran
    /// first.
    static let warmups = 3
    static let iterations = 20

    func testRenderBenchmarkMedians() throws {
        let note = Self.syntheticNote()
        let bytes = note.utf8.count
        XCTAssertGreaterThan(bytes, 200 * 1024, "the fixture must be the size we claim")

        // Parse, measured on its own: this is what runs before a single block can be drawn.
        var parseSamples: [Double] = []
        for i in 0..<(Self.warmups + Self.iterations) {
            let started = ContinuousClock.now
            let document = VaultNoteDocument.parse(path: "Workshop/Bench.md", text: note,
                                                  byteLimit: Int.max)
            let elapsed = ContinuousClock.now - started
            XCTAssertFalse(document.blocks.isEmpty)
            if i >= Self.warmups { parseSamples.append(Self.millis(elapsed)) }
        }

        let document = VaultNoteDocument.parse(path: "Workshop/Bench.md", text: note,
                                               byteLimit: Int.max)
        let resolved = Self.resolvedMap(document)

        // THE RENDER NUMBER THE BUDGET IS WRITTEN AGAINST, and it is measured over the
        // note's own NON-BLANK LINES rather than over its blocks. That needs saying,
        // because "over every block" is the obvious thing to measure and it is the wrong
        // thing to COMPARE:
        //
        //     The whole point of the new block model is that a block is no longer a line.
        //     A paragraph is one block instead of six; a table is one block whose text is
        //     empty, because its content lives in its cells. Measuring "every block's
        //     text" therefore measures a different quantity of text on each side of the
        //     change, and the new side would look faster mostly by having handed less
        //     text to the function under test.
        //
        // The lines are identical on both sides, so this is a true like-for-like
        // throughput measurement of `attributed`. The block-shaped number is reported
        // underneath it as context, and the parse median plus the app's own open-time
        // measurement cover what the block model changed.
        let lines = note.split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var renderSamples: [Double] = []
        for i in 0..<(Self.warmups + Self.iterations) {
            let started = ContinuousClock.now
            var characters = 0
            for line in lines {
                characters += VaultNoteRenderer.attributed(line, resolved: resolved)
                    .characters.count
            }
            let elapsed = ContinuousClock.now - started
            XCTAssertGreaterThan(characters, 0)
            if i >= Self.warmups { renderSamples.append(Self.millis(elapsed)) }
        }

        // The same pass over the blocks the reader actually draws. Reported, not budgeted.
        var blockSamples: [Double] = []
        for i in 0..<(Self.warmups + Self.iterations) {
            let started = ContinuousClock.now
            for block in document.blocks {
                _ = VaultNoteRenderer.attributed(block.text, resolved: resolved)
            }
            let elapsed = ContinuousClock.now - started
            if i >= Self.warmups { blockSamples.append(Self.millis(elapsed)) }
        }

        print("""

            === VAULT RENDER BENCHMARK ===
            fixture:        \(bytes) bytes, \(note.split(separator: "\n", omittingEmptySubsequences: false).count) lines
            blocks:         \(document.blocks.count)
            rendered lines: \(lines.count)
            iterations:     \(Self.iterations) measured after \(Self.warmups) warm-ups
            parse median:   \(Self.format(Self.median(parseSamples))) ms
            render median:  \(Self.format(Self.median(renderSamples))) ms
            block median:   \(Self.format(Self.median(blockSamples))) ms  (context, not the budget)
            parse range:    \(Self.format(parseSamples.min() ?? 0)) .. \(Self.format(parseSamples.max() ?? 0)) ms
            render range:   \(Self.format(renderSamples.min() ?? 0)) .. \(Self.format(renderSamples.max() ?? 0)) ms
            ==============================

            """)
    }

    /// THE THIRD NUMBER: opening the note, end to end, through the reader's own model.
    ///
    /// A scratch folder holding the 250 KB note plus a hundred small ones, adopted the way
    /// a device adopts one, indexed the way a device indexes one, and then
    /// `VaultNoteReaderModel.load` five times. That call is the coordinated file read, the
    /// parse, and the link resolution — everything between the tap and the moment the
    /// reader has something to draw.
    ///
    /// What it deliberately does NOT include is SwiftUI's own layout of the first frame,
    /// which cannot be measured without driving a window. The report says so.
    @MainActor
    func testNoteOpenBenchmark() async throws {
        let suiteName = "jesse.vault.bench.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = VaultFixture.makeDirectory()
        let container = VaultFixture.makeDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            VaultFixture.cleanUp(root)
            VaultFixture.cleanUp(container)
        }

        let note = Self.syntheticNote()
        VaultFixture.write(note, to: "Workshop/Bench.md", in: root)
        for i in 0..<100 {
            VaultFixture.write("""
                # Small note \(i)

                A paragraph about [[Workshop/Bench]] and the yard.
                """, to: "Notes/Small-\(i).md", in: root)
        }

        let folder = VaultFolder(defaults: defaults, key: "bench.bookmark")
        try folder.adopt(url: root)
        let source = VaultIndexSource(folder: folder, container: container)
        await VaultIndexer(source: source).reindexNow()

        var samples: [Double] = []
        for i in 0..<(Self.warmups + 5) {
            // A FRESH MODEL EACH TIME, because a reused one would be measuring a second
            // load into warm caches, which is not what opening a note from a list does.
            let reader = VaultNoteReaderModel(source: source)
            let started = ContinuousClock.now
            await reader.load(path: "Workshop/Bench.md")
            let elapsed = ContinuousClock.now - started
            XCTAssertNotNil(reader.document)
            if i >= Self.warmups { samples.append(Self.millis(elapsed)) }
        }

        print("""

            === VAULT NOTE OPEN BENCHMARK ===
            folder:         1 note of \(note.utf8.count) bytes + 100 small ones
            opens measured: \(samples.count) after \(Self.warmups) warm-ups
            open median:    \(Self.format(Self.median(samples))) ms
            open range:     \(Self.format(samples.min() ?? 0)) .. \(Self.format(samples.max() ?? 0)) ms
            =================================

            """)
    }

    // MARK: - Statistics

    static func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func millis(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Every wiki target in the note resolved to a path, so the render pass does the
    /// EXPENSIVE thing (building a link) rather than the cheap one (falling through to
    /// plain text) for each link it meets.
    static func resolvedMap(_ document: VaultNoteDocument) -> [String: String] {
        var map: [String: String] = [:]
        for target in document.wikiTargets { map[target] = target + ".md" }
        return map
    }

    // MARK: - The fixture

    /// One note of about 250 KB using every construct this vault writes.
    ///
    /// Built by repeating a SECTION rather than a line, so the mix of constructs is the
    /// mix a real note has rather than a thousand copies of the cheapest one.
    static func syntheticNote() -> String {
        var out = """
            ---
            title: The Long Bench Note
            tags: bench, pottery
            ---

            """
        var section = 0
        while out.utf8.count < 250 * 1024 {
            section += 1
            out += self.section(section)
        }
        return out
    }

    static func section(_ n: Int) -> String {
        var s = ""
        s += "# Firing \(n)\n\n"
        s += """
            The floor of the chamber cracked along the back seam again, and the crack \
            runs further than it did in the spring.
            Measured cold it is about four millimetres at the widest point, narrowing to \
            nothing under the bag wall.
            The soft brick above it is sound, which is the only reason this is a repair \
            and not a rebuild.

            """
        s += "\n## Materials\n\n"
        s += "- soft brick, grade 26, from [[Suppliers/Terrasole]]\n"
        s += "\t- the pallet is still in the yard\n"
        s += "\t\t- forty two of them, counted twice\n"
        s += "- castable, one bag, see [[Suppliers/Terrasole|the price list]]\n"
        s += "- [ ] order the anchors\n"
        s += "- [x] measure the arch\n"
        s += "\n### The order\n\n"
        s += "1. strip the old floor back to the brick\n"
        s += "1. wet it down the night before\n"
        s += "1. pour in two lifts, not one\n"
        s += "4. leave it a week before the first firing\n"
        s += "\n#### A note on the schedule\n\n"
        s += "> The yard is closed for the whole of August, so anything not ordered by\n"
        s += "> the last week of July waits until September. That is the constraint the\n"
        s += "> rest of this plan is built around.\n"
        s += "\n##### Cone chart\n\n"
        s += "| Cone | Ramp | Hold | Kiln | Shelf | Result |\n"
        s += "|:--|--:|:-:|---|---|---|\n"
        for row in 1...40 {
            s += "| \(row).0 | \(60 + row) C/h | \(row % 5) min | **big** | _top_ | "
            s += "see [[Firings/Log \(n)]] |\n"
        }
        s += "\n###### Cost\n\n"
        s += "The castable is quoted at ninety euro the bag, which is up from seventy, "
        s += "and the [supplier's page](https://example.invalid/castable) has not been "
        s += "updated since the spring.\n\n"
        s += "```swift\n"
        s += "let ramp = Ramp(perHour: 60, hold: .minutes(20))\n"
        s += "    .capped(at: .cone(6))\n"
        s += "```\n\n"
        s += "---\n\n"
        return s
    }
}
