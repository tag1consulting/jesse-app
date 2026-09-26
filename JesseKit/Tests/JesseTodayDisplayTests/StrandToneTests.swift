import XCTest
import SwiftUI
@testable import JesseTodayDisplay
import JesseNetworking

// Strand family tones, measured rather than admired, in the manner of
// `TodayProjectPaletteTests`: every property the palette header promises for a strand's
// tone is asserted here over computed values, at every depth the derivation can take,
// with the colour vision simulations done in the test rather than trusted from a tool.
//
// The contract, in one list:
//
//   * every tone, root or derived, clears 3:1 against its own background;
//   * every PAIR of the eight named root tones is at least ΔE*ab 20 apart under normal
//     vision, in each appearance;
//   * every level is at least ΔE*ab 12 from the level above it;
//   * every child, to the third level, is closer to its OWN root than to any other root;
//   * the three colour vision minimums are PRINTED, never asserted — see
//     `testColourVisionMinimumsAreReported`.

final class StrandToneTests: XCTestCase {

    private let schemes: [ColorScheme] = [.light, .dark]

    /// The eight roots the vault holds, by the slug the bridge sends for each.
    private let namedRoots = ["Tag1", "Homelab", "Perseido", "Via-Con-Me",
                              "Family", "Trovato", "Health", "Tangent"]

    private func background(_ scheme: ColorScheme) -> TodayProjectColor {
        scheme == .dark ? StrandTone.darkBackground : StrandTone.lightBackground
    }

    private func tone(_ root: String, _ depth: Int, _ scheme: ColorScheme) -> TodayProjectColor {
        StrandTone.color(root: root, depth: depth, scheme: scheme)
    }

    // MARK: - OKLCH

    /// The conversion round trips: every palette colour, and a spread of sRGB values,
    /// come back within 1/255 per channel.
    func testOKLCHRoundTripsWithinOneStep() {
        var colours = TodayProjectPalette.roles.flatMap { [$0.light, $0.dark] }
        for r in stride(from: 0.0, through: 1, by: 0.25) {
            for g in stride(from: 0.0, through: 1, by: 0.25) {
                for b in stride(from: 0.0, through: 1, by: 0.25) {
                    colours.append(TodayProjectColor(red: r, green: g, blue: b))
                }
            }
        }
        for colour in colours {
            let back = OKLCH(colour).sRGB
            for (x, y) in [(colour.red, back.red), (colour.green, back.green),
                           (colour.blue, back.blue)] {
                XCTAssertEqual(x, y, accuracy: 1.0 / 255, "\(colour) came back as \(back)")
            }
        }
    }

    /// Gamut mapping keeps lightness and hue and gives up chroma: an impossible blue
    /// comes back as a real colour of the same hue.
    func testGamutMappingReducesChromaOnly() {
        let wild = OKLCH(lightness: 0.6, chroma: 0.5, hue: 250)
        XCTAssertFalse(wild.isInGamut)
        let mapped = OKLCH(wild.sRGB)
        XCTAssertEqual(mapped.lightness, 0.6, accuracy: 0.005)
        XCTAssertEqual(mapped.hue, 250, accuracy: 1)
        XCTAssertLessThan(mapped.chroma, 0.5)
    }

    // MARK: - The table

    /// The table names the eight roots the vault holds, and reads them whatever case the
    /// bridge spells the slug in.
    func testTheTableNamesTheEightLiveRoots() {
        XCTAssertEqual(StrandTone.roots.count, 8)
        XCTAssertEqual(Set(StrandTone.roots.keys),
                       Set(namedRoots.map { $0.lowercased() }))
        for root in namedRoots {
            XCTAssertEqual(StrandTone.slot(forRoot: root),
                           StrandTone.slot(forRoot: root.lowercased()), root)
            XCTAssertEqual(StrandTone.slot(forRoot: root),
                           StrandTone.roots[root.lowercased()], root)
        }
    }

    /// **Two families are never one colour**, which is the whole point of the table: the
    /// eight roots are eight visibly different colours in each appearance, and the two
    /// pairs Jeremy called out (Family with Trovato, Health with Tangent — all four
    /// filed under Personal) are as far apart as any other pair.
    func testEveryPairOfNamedRootsIsTwentyApart() {
        for scheme in schemes {
            for (i, a) in namedRoots.enumerated() {
                for b in namedRoots[(i + 1)...] {
                    let d = deltaE(Vision.normal.apply(tone(a, 0, scheme)),
                                   Vision.normal.apply(tone(b, 0, scheme)))
                    XCTAssertGreaterThanOrEqual(
                        d, 20, "\(scheme) \(a) vs \(b): ΔE \(fmt(d))")
                }
            }
        }
        for scheme in schemes {
            XCTAssertNotEqual(tone("Family", 0, scheme), tone("Trovato", 0, scheme))
            XCTAssertNotEqual(tone("Health", 0, scheme), tone("Tangent", 0, scheme))
        }
    }

    /// Every tone the table can produce — the eight named roots and the four spares, at
    /// every depth — clears the 3:1 non text threshold against its own background.
    func testEveryToneClearsNonTextContrast() {
        for scheme in schemes {
            for root in namedRoots + unknownRoots {
                for depth in 0...StrandTone.maxDepth {
                    let ratio = tone(root, depth, scheme).contrast(with: background(scheme))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3, "\(root) d\(depth) \(scheme) is \(fmt(ratio)):1")
                }
            }
        }
    }

    /// **A child is visibly not its parent.** Every level is at least ΔE 12 from the
    /// level above it — the fault this replaces stepped about 5, which on a 4 point bar
    /// is nothing: Homelab and K3s Cluster read as one purple.
    func testEachLevelIsTwelveFromTheLevelAbove() {
        for scheme in schemes {
            for root in namedRoots + unknownRoots {
                for depth in 1...StrandTone.maxDepth {
                    let d = deltaE(Vision.normal.apply(tone(root, depth, scheme)),
                                   Vision.normal.apply(tone(root, depth - 1, scheme)))
                    XCTAssertGreaterThanOrEqual(
                        d, 12, "\(root) d\(depth) \(scheme): ΔE \(fmt(d)) from d\(depth - 1)")
                }
            }
        }
    }

    /// **No child wanders into another family.** At every depth, a child is closer to its
    /// own root than to any other named root, so a deep Tag1 strand can never read as the
    /// Homelab family.
    func testEveryChildStaysNearestItsOwnRoot() {
        for scheme in schemes {
            for root in namedRoots {
                for depth in 1...StrandTone.maxDepth {
                    let child = Vision.normal.apply(tone(root, depth, scheme))
                    let own = deltaE(child, Vision.normal.apply(tone(root, 0, scheme)))
                    for other in namedRoots where other != root {
                        let away = deltaE(child, Vision.normal.apply(tone(other, 0, scheme)))
                        XCTAssertGreaterThan(
                            away, own,
                            "\(scheme) \(root) d\(depth): own \(fmt(own)), \(other) \(fmt(away))")
                    }
                }
            }
        }
    }

    /// The step goes AWAY from the background in both appearances — darker on white,
    /// lighter on `#1C1C1E` — so a deeper strand is a stronger mark and not a fainter one.
    func testTheStepMovesAwayFromTheBackground() {
        XCTAssertLessThan(StrandTone.step(.light), 0)
        XCTAssertGreaterThan(StrandTone.step(.dark), 0)
        for scheme in schemes {
            for root in namedRoots {
                for depth in 1...StrandTone.maxDepth {
                    let nearer = tone(root, depth - 1, scheme).contrast(with: background(scheme))
                    let further = tone(root, depth, scheme).contrast(with: background(scheme))
                    XCTAssertGreaterThan(further, nearer, "\(root) d\(depth) \(scheme)")
                }
            }
        }
    }

    /// Stepping stops at `maxDepth`: anything deeper wears that level's tone, which is a
    /// tone the assertions above have measured.
    func testDepthIsCapped() {
        for scheme in schemes {
            for root in namedRoots {
                XCTAssertEqual(tone(root, StrandTone.maxDepth + 1, scheme),
                               tone(root, StrandTone.maxDepth, scheme), root)
                XCTAssertEqual(tone(root, 99, scheme),
                               tone(root, StrandTone.maxDepth, scheme), root)
            }
        }
    }

    // MARK: - Unknown roots

    /// A root slug nobody has heard of takes one of four spare slots by a stable hash,
    /// keeps it when the board changes around it, and lands at least ΔE 12 from every
    /// named root — the weaker promise the header states, because twelve hues cannot all
    /// be twenty apart.
    func testAnUnknownRootTakesAStableSpareSlot() {
        XCTAssertEqual(StrandTone.spares.count, 4)
        for root in unknownRoots {
            XCTAssertTrue(StrandTone.spares.contains(StrandTone.slot(forRoot: root)), root)
            XCTAssertEqual(StrandTone.slot(forRoot: root), StrandTone.slot(forRoot: root))
            XCTAssertEqual(StrandTone.slot(forRoot: root),
                           StrandTone.slot(forRoot: root.uppercased()), root)
        }
        XCTAssertGreaterThan(Set(unknownRoots.map { StrandTone.slot(forRoot: $0).hue }).count, 1,
                             "the spares are never all the same slot")
        for scheme in schemes {
            for spare in StrandTone.spares {
                for named in namedRoots {
                    let d = deltaE(Vision.normal.apply(spare.root(scheme).sRGB),
                                   Vision.normal.apply(tone(named, 0, scheme)))
                    XCTAssertGreaterThanOrEqual(
                        d, 12, "\(scheme) spare \(spare.hue) vs \(named): ΔE \(fmt(d))")
                }
            }
        }
    }

    /// The slot hash is FNV 1a, pinned: the same slug gives the same slot on every launch
    /// and every platform.
    func testTheSlotHashIsPinned() {
        XCTAssertEqual(StrandTone.fnv1a(""), 0x811C9DC5)
        XCTAssertEqual(StrandTone.fnv1a("a"), 0xE40C292C)
        XCTAssertEqual(StrandTone.fnv1a("foobar"), 0xBF9CF968)
    }

    /// A slug the board does not hold at all has no family to read and draws the neutral.
    func testAnAbsentSlugDrawsTheNeutral() {
        for scheme in schemes {
            XCTAssertEqual(StrandTone.color(for: "Nobody", in: [], scheme: scheme),
                           StrandTone.neutral(scheme))
            XCTAssertTrue(StrandTone.neutral(scheme).isNeutral)
        }
    }

    // MARK: - Resolving a family from the snapshot

    /// The live shape of the board: eight roots, and the children the vault has under
    /// them today.
    private let liveShape: [Strand] = [
        Strand(slug: "Tag1", title: "Tag1", group: .tag1),
        Strand(slug: "Jesse", title: "Jesse", group: .tag1, parent: "Tag1"),
        Strand(slug: "Strands-System", title: "Strands System", group: .tag1, parent: "Jesse"),
        Strand(slug: "DrupalCon-Rotterdam", title: "DrupalCon Rotterdam", group: .tag1, parent: "Tag1"),
        Strand(slug: "Scolta-DrupalCon-Talk", title: "Scolta DrupalCon Talk", group: .tag1,
               parent: "DrupalCon-Rotterdam"),
        Strand(slug: "Homelab", title: "Homelab", group: .network),
        Strand(slug: "K3s-Cluster", title: "K3s Cluster", group: .network, parent: "Homelab"),
        Strand(slug: "Perseido", title: "Perseido", group: .perseido),
        Strand(slug: "Via-Con-Me", title: "Via Con Me", group: .viaConMe),
        Strand(slug: "Family", title: "Family", group: .personal),
        Strand(slug: "Greta", title: "Greta", group: .personal, parent: "Family"),
        Strand(slug: "Trovato", title: "Trovato", group: .personal),
        Strand(slug: "Trovato-Core", title: "Trovato Core", group: .personal, parent: "Trovato"),
        Strand(slug: "Argus", title: "Argus", group: .personal, parent: "Trovato"),
        Strand(slug: "Health", title: "Health", group: .personal),
        Strand(slug: "Tangent", title: "Tangent", group: .personal),
    ]

    /// A strand's family is its topmost ancestor and its depth is edges from it, whatever
    /// topics the chain passes through: a strand's colour is its family's, and a family is
    /// not a topic.
    func testTheFamilyWalkIsStructural() {
        let bySlug = Dictionary(liveShape.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        func family(_ slug: String) -> (root: String, depth: Int) {
            StrandTone.family(of: bySlug[slug]!, in: bySlug)
        }
        XCTAssertEqual(family("Tag1").root, "Tag1")
        XCTAssertEqual(family("Tag1").depth, 0)
        XCTAssertEqual(family("Jesse").depth, 1)
        XCTAssertEqual(family("Strands-System").root, "Tag1")
        XCTAssertEqual(family("Strands-System").depth, 2)
        XCTAssertEqual(family("Scolta-DrupalCon-Talk").root, "Tag1")
        XCTAssertEqual(family("Scolta-DrupalCon-Talk").depth, 2)
        XCTAssertEqual(family("K3s-Cluster").root, "Homelab")
        XCTAssertEqual(family("K3s-Cluster").depth, 1)

        // A parent in another topic is still a parent, and a parent the snapshot does not
        // serve makes the child a root of its own.
        let crossing = [Strand(slug: "Tag1", group: .tag1),
                        Strand(slug: "Crosser", group: .personal, parent: "Tag1"),
                        Strand(slug: "Orphan", group: .perseido, parent: "Not-Here")]
        let crossIndex = Dictionary(crossing.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(StrandTone.family(of: crossing[1], in: crossIndex).root, "Tag1")
        XCTAssertEqual(StrandTone.family(of: crossing[1], in: crossIndex).depth, 1)
        XCTAssertEqual(StrandTone.family(of: crossing[2], in: crossIndex).root, "Orphan")
        XCTAssertEqual(StrandTone.family(of: crossing[2], in: crossIndex).depth, 0)
    }

    /// A bridge that sends no `parent` makes every strand a root, so every strand draws
    /// its own slot.
    func testAnOlderBridgeDrawsEveryStrandAsARoot() throws {
        let json = #"{"strands":[{"slug":"Tag1","group":"tag1"},{"slug":"Homelab","group":"network"}]}"#
        let snapshot = try StrandsSnapshot.decode(from: Data(json.utf8))
        XCTAssertFalse(snapshot.servesParents)
        for scheme in schemes {
            XCTAssertEqual(StrandTone.color(for: "Tag1", in: snapshot, scheme: scheme),
                           tone("Tag1", 0, scheme))
            XCTAssertEqual(StrandTone.color(for: "Homelab", in: snapshot, scheme: scheme),
                           tone("Homelab", 0, scheme))
        }
    }

    /// A loop the bridge should never send still yields a tone, and the table covers every
    /// strand.
    func testALoopStillYieldsATone() {
        let loop = [Strand(slug: "A", group: .tag1, parent: "B"),
                    Strand(slug: "B", group: .tag1, parent: "A")]
        let table = StrandTone.table(for: loop, scheme: .light)
        XCTAssertEqual(Set(table.keys), ["A", "B"])
    }

    /// Siblings share a tone, and nothing a sibling does moves anybody: adding, renaming
    /// or reordering one leaves every existing tone exactly where it was.
    func testSiblingsShareAToneAndNeverMoveEachOther() {
        let grown = [Strand(slug: "Jesse-Newcomer", group: .tag1, parent: "Jesse")]
            + liveShape.reversed()
        for scheme in schemes {
            let before = StrandTone.table(for: liveShape, scheme: scheme)
            let after = StrandTone.table(for: grown, scheme: scheme)
            for strand in liveShape {
                XCTAssertEqual(before[strand.slug], after[strand.slug], strand.slug)
            }
            XCTAssertEqual(after["Jesse-Newcomer"], after["Strands-System"],
                           "\(scheme): siblings at one depth share a tone")
            XCTAssertEqual(before["Trovato-Core"], before["Argus"])
        }
    }

    /// **One function, every surface.** The board's per row lookup, the whole board table
    /// and the raw root plus depth call all answer the same colour, so a strand cannot be
    /// one colour in a row's bar and another in a caption's dot.
    func testEverySurfaceResolvesTheSameTone() {
        for scheme in schemes {
            let board = StrandFamily(strands: liveShape, scheme: scheme)
            let table = StrandTone.table(for: liveShape, scheme: scheme)
            for strand in liveShape {
                let direct = StrandTone.color(for: strand.slug, in: liveShape, scheme: scheme)
                XCTAssertEqual(board.tone(strand.slug), direct, strand.slug)
                XCTAssertEqual(table[strand.slug], direct, strand.slug)
            }
            XCTAssertEqual(board.tone("Jesse"), tone("Tag1", 1, scheme))
            XCTAssertEqual(board.tone("K3s-Cluster"), tone("Homelab", 1, scheme))
            XCTAssertEqual(board.tone("Nobody-Here"), StrandTone.neutral(scheme))
        }
    }

    /// The live board has no two roots of one colour and no child that matches its parent.
    func testTheLiveBoardHasNoRepeatedTone() {
        for scheme in schemes {
            let board = StrandFamily(strands: liveShape, scheme: scheme)
            let roots = liveShape.filter { $0.parent == nil }.map { board.tone($0.slug) }
            XCTAssertEqual(Set(roots).count, roots.count, "\(scheme): two roots share a tone")
            for strand in liveShape {
                guard let parent = board.parent(of: strand) else { continue }
                XCTAssertNotEqual(board.tone(strand.slug), board.tone(parent.slug),
                                  "\(scheme) \(strand.slug)")
            }
        }
    }

    /// A child says where it sits, to a screen reader and in the flat lenses' caption,
    /// right after its title; a root says nothing extra.
    func testAChildSaysItsParent() {
        XCTAssertEqual(StrandsSemantics.parentCaption("Jesse"), "in Jesse")
        let board = StrandFamily(strands: liveShape, scheme: .light)
        XCTAssertNil(board.parent(of: liveShape[0]))
        XCTAssertEqual(board.parent(of: liveShape[2])?.title, "Jesse")
        let label = StrandsSemantics.rowAccessibilityLabel(liveShape[2], today: "2026-09-26",
                                                          parentTitle: "Jesse")
        XCTAssertTrue(label.hasPrefix("Project: Tag1, Strands System, in Jesse"), label)
        let root = StrandsSemantics.rowAccessibilityLabel(liveShape[0], today: "2026-09-26")
        XCTAssertFalse(root.contains(" in "), root)
    }

    // MARK: - Colour vision, reported

    /// **The three colour vision minimums, printed and not gated.** Eight hues cannot all
    /// survive a dichromacy — deuteranopia alone collapses red against green — and the
    /// alternative to accepting that is fewer than eight distinguishable families, which
    /// is the bug. Every row that carries a tone carries the strand's NAME beside it, so
    /// the colour is the second cue and never the only one. The numbers are here so a
    /// future edit can see whether it made them better or worse.
    func testColourVisionMinimumsAreReported() {
        for scheme in schemes {
            for vision in [Vision.protanopia, .deuteranopia, .tritanopia] {
                var worst = (Double.infinity, "", "")
                for (i, a) in namedRoots.enumerated() {
                    for b in namedRoots[(i + 1)...] {
                        let d = deltaE(vision.apply(tone(a, 0, scheme)),
                                       vision.apply(tone(b, 0, scheme)))
                        if d < worst.0 { worst = (d, a, b) }
                    }
                }
                print("COLOUR VISION \(scheme) \(vision): minimum root ΔE*ab "
                      + "\(fmt(worst.0)) (\(worst.1) vs \(worst.2))")
                XCTAssertGreaterThan(worst.0, 0)
            }
        }
    }

    /// The eight root tones as hex, in both appearances, in the test log: what a reviewer
    /// checks the screenshots against.
    func testRootToneHexesAreReported() {
        for scheme in schemes {
            for root in namedRoots {
                let ramp = (0...StrandTone.maxDepth).map { hex(tone(root, $0, scheme)) }
                print("ROOT TONE \(scheme) \(root): " + ramp.joined(separator: " "))
            }
        }
    }

    private func hex(_ colour: TodayProjectColor) -> String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(colour.red), byte(colour.green), byte(colour.blue))
    }

    /// Four slugs the table has never heard of, one per spare slot when the hash is kind
    /// and in any case a spread of unknowns.
    private let unknownRoots = ["Kiln-Rebuild", "Olive-Harvest", "Zzyzx", "Sopralluogo"]

    // MARK: - Colour maths
    //
    // The same measurement `TodayProjectPaletteTests` makes, restated here because that
    // file keeps its maths private and is not edited by this suite.

    private static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    enum Vision: String, CaseIterable, CustomStringConvertible {
        case normal, protanopia, deuteranopia, tritanopia

        var description: String { rawValue }

        var matrix: [[Double]]? {
            switch self {
            case .normal: return nil
            case .protanopia:
                return [[0.152286, 1.052583, -0.204868],
                        [0.114503, 0.786281, 0.099216],
                        [-0.003882, -0.048116, 1.051998]]
            case .deuteranopia:
                return [[0.367322, 0.860646, -0.227968],
                        [0.280085, 0.672501, 0.047413],
                        [-0.011820, 0.042940, 0.968881]]
            case .tritanopia:
                return [[1.255528, -0.076749, -0.178779],
                        [-0.078411, 0.930809, 0.147602],
                        [0.004733, 0.691367, 0.303900]]
            }
        }

        func apply(_ colour: TodayProjectColor) -> [Double] {
            let v = [StrandToneTests.toLinear(colour.red), StrandToneTests.toLinear(colour.green),
                     StrandToneTests.toLinear(colour.blue)]
            guard let m = matrix else { return v }
            return m.map { row in (0..<3).reduce(0.0) { $0 + row[$1] * v[$1] } }
        }
    }

    private func lab(_ linear: [Double]) -> [Double] {
        let (r, g, b) = (linear[0], linear[1], linear[2])
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0
        }
        let (fx, fy, fz) = (f(max(x, 0) / 0.95047), f(max(y, 0)), f(max(z, 0) / 1.08883))
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    func deltaE(_ a: [Double], _ b: [Double]) -> Double {
        let (la, lb) = (lab(a), lab(b))
        return sqrt(zip(la, lb).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
}
