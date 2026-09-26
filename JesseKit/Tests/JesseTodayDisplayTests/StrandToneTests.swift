import XCTest
import SwiftUI
@testable import JesseTodayDisplay
import JesseNetworking

// Strand family tones, measured rather than admired, in the manner of
// `TodayProjectPaletteTests`: every property the palette header promises for a derived
// tone is asserted here over computed values, for every path the derivation can take,
// with the colour vision simulations done in the test rather than trusted from a tool.
//
// "Every path" is exhaustive, not sampled: four slots and four levels is 340 paths per
// topic per appearance, so the suite walks all of them.

final class StrandToneTests: XCTestCase {

    private let schemes: [ColorScheme] = [.light, .dark]

    /// Every slot sequence from one level to `maxDepth` levels.
    private var allPaths: [[Double]] {
        var out: [[Double]] = []
        var frontier: [[Double]] = [[]]
        for _ in 0..<StrandTone.maxDepth {
            frontier = frontier.flatMap { path in StrandTone.slots.map { path + [$0] } }
            out += frontier
        }
        return out
    }

    private func base(_ project: TodayProject, _ scheme: ColorScheme) -> TodayProjectColor {
        let role = TodayProjectPalette.role(for: project)
        return scheme == .dark ? role.dark : role.light
    }

    private func background(_ scheme: ColorScheme) -> TodayProjectColor {
        scheme == .dark ? StrandTone.darkBackground : StrandTone.lightBackground
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

    // MARK: - Roots

    /// A root is its topic's base EXACTLY, so a root strand and a Today item of the same
    /// topic match to the bit.
    func testARootIsItsTopicBaseExactly() {
        let strands = [
            Strand(slug: "Tag1", group: .tag1),
            Strand(slug: "Homelab", group: .network, parent: nil),
            Strand(slug: "Orphan", group: .perseido, parent: "Not-Here"),
            Strand(slug: "Crosser", group: .personal, parent: "Tag1"),
        ]
        for scheme in schemes {
            XCTAssertEqual(StrandTone.color(for: "Tag1", in: strands, scheme: scheme),
                           base(.tag1, scheme))
            XCTAssertEqual(StrandTone.color(for: "Homelab", in: strands, scheme: scheme),
                           base(.network, scheme))
            XCTAssertEqual(StrandTone.color(for: "Orphan", in: strands, scheme: scheme),
                           base(.perseido, scheme), "an unresolved parent makes a root")
            XCTAssertEqual(StrandTone.color(for: "Crosser", in: strands, scheme: scheme),
                           base(.personal, scheme), "a parent in another topic makes a root")
        }
    }

    /// A bridge that sends no `parent` draws every strand in its topic base, as before.
    func testAnOlderBridgeDrawsEveryStrandInItsTopicBase() throws {
        let json = #"{"strands":[{"slug":"A","group":"tag1"},{"slug":"B","group":"network"}]}"#
        let snapshot = try StrandsSnapshot.decode(from: Data(json.utf8))
        XCTAssertFalse(snapshot.servesParents)
        for scheme in schemes {
            XCTAssertEqual(StrandTone.color(for: "A", in: snapshot, scheme: scheme),
                           base(.tag1, scheme))
            XCTAssertEqual(StrandTone.color(for: "B", in: snapshot, scheme: scheme),
                           base(.network, scheme))
        }
    }

    // MARK: - Stability

    /// The slot hash is FNV 1a, pinned: the same slug gives the same slot on every
    /// launch and every platform.
    func testTheSlotHashIsPinned() {
        XCTAssertEqual(StrandTone.fnv1a(""), 0x811C9DC5)
        XCTAssertEqual(StrandTone.fnv1a("a"), 0xE40C292C)
        XCTAssertEqual(StrandTone.fnv1a("foobar"), 0xBF9CF968)
    }

    /// The same slug always gets the same tone, and adding, renaming or reordering a
    /// sibling changes no existing tone.
    func testSiblingsNeverMoveEachOther() {
        let family = [
            Strand(slug: "Tag1", group: .tag1),
            Strand(slug: "Jesse", group: .tag1, parent: "Tag1"),
            Strand(slug: "Strands-System", group: .tag1, parent: "Jesse"),
            Strand(slug: "Vault-Links", group: .tag1, parent: "Jesse"),
        ]
        let grown = [Strand(slug: "Jesse-Newcomer", group: .tag1, parent: "Jesse")]
            + family.reversed()
        for scheme in schemes {
            let before = StrandTone.table(for: family, scheme: scheme)
            let after = StrandTone.table(for: grown, scheme: scheme)
            for strand in family {
                XCTAssertEqual(before[strand.slug], after[strand.slug], strand.slug)
                XCTAssertEqual(before[strand.slug],
                               StrandTone.color(for: strand.slug, in: family, scheme: scheme))
            }
        }
    }

    /// A loop the bridge should never send still yields a tone, and the table covers
    /// every strand.
    func testALoopStillYieldsATone() {
        let loop = [Strand(slug: "A", group: .tag1, parent: "B"),
                    Strand(slug: "B", group: .tag1, parent: "A")]
        let table = StrandTone.table(for: loop, scheme: .light)
        XCTAssertEqual(Set(table.keys), ["A", "B"])
    }

    /// A strand deeper than `maxDepth` wears the tone of its ancestor at that depth,
    /// which is a tone the contract tests below have measured.
    func testDepthIsCapped() {
        var chain = [Strand(slug: "L0", group: .tag1)]
        for level in 1...6 {
            chain.append(Strand(slug: "L\(level)", group: .tag1, parent: "L\(level - 1)"))
        }
        let table = StrandTone.table(for: chain, scheme: .dark)
        XCTAssertEqual(table["L5"], table["L4"])
        XCTAssertEqual(table["L6"], table["L4"])
        XCTAssertNotEqual(table["L4"], table["L3"])
    }

    // MARK: - The contract

    /// Every derived tone, at every depth and slot, clears the 3:1 non text threshold
    /// against its own background.
    func testEveryDerivedToneClearsNonTextContrast() {
        for project in TodayProject.allCases {
            for scheme in schemes {
                for path in allPaths {
                    let tone = StrandTone.color(path: path, project: project, scheme: scheme)
                    let ratio = tone.contrast(with: background(scheme))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3, "\(project) \(scheme) \(path) is \(fmt(ratio)):1")
                }
            }
        }
    }

    /// **No tone wanders into another topic.** Every derived tone stays at least ΔE 10
    /// from every OTHER topic's base, under normal vision and the three dichromacies: a
    /// Tag1 grandchild must never read as Network purple.
    func testNoDerivedToneReachesAnotherTopic() {
        for project in TodayProject.allCases {
            for scheme in schemes {
                let others = TodayProject.allCases.filter { $0 != project }
                for path in allPaths {
                    let tone = StrandTone.color(path: path, project: project, scheme: scheme)
                    for other in others {
                        for vision in Vision.allCases {
                            let d = deltaE(vision.apply(tone), vision.apply(base(other, scheme)))
                            XCTAssertGreaterThanOrEqual(
                                d, 10,
                                "\(project) \(scheme) \(path) vs \(other) \(vision): ΔE \(fmt(d))")
                        }
                    }
                }
            }
        }
    }

    /// A child is visibly not its parent: at least ΔE 5 under normal vision, at every
    /// level.
    func testAChildDiffersFromItsParent() {
        for project in TodayProject.allCases {
            for scheme in schemes {
                for path in allPaths {
                    let child = StrandTone.color(path: path, project: project, scheme: scheme)
                    let parent = StrandTone.color(path: Array(path.dropLast()),
                                                  project: project, scheme: scheme)
                    let d = deltaE(Vision.normal.apply(child), Vision.normal.apply(parent))
                    XCTAssertGreaterThanOrEqual(
                        d, 5, "\(project) \(scheme) \(path): ΔE \(fmt(d)) from its parent")
                }
            }
        }
    }

    /// `unfiled` stays neutral at every depth: "no project" must never grow a hue.
    func testUnfiledTonesStayNeutral() {
        for scheme in schemes {
            for path in allPaths {
                let tone = StrandTone.color(path: path, project: .unfiled, scheme: scheme)
                XCTAssertLessThan(OKLCH(tone).chroma, 0.001, "\(scheme) \(path)")
            }
        }
    }

    // MARK: - The board's families

    private let liveShape = [
        Strand(slug: "Tag1", title: "Tag1", group: .tag1),
        Strand(slug: "Jesse", title: "Jesse", group: .tag1, parent: "Tag1"),
        Strand(slug: "Strands-System", title: "Strands System", group: .tag1, parent: "Jesse"),
        Strand(slug: "Trovato", title: "Trovato", group: .personal),
        Strand(slug: "Argus", title: "Argus", group: .personal, parent: "Trovato"),
    ]

    /// Tag1, Jesse and Strands System are three different blues of one family: every
    /// pair differs, and the root is Tag1's own blue.
    func testAFamilyIsThreeDifferentTones() {
        for scheme in schemes {
            let family = StrandFamily(strands: liveShape, scheme: scheme)
            let tones = ["Tag1", "Jesse", "Strands-System"].map(family.tone)
            XCTAssertEqual(tones[0], base(.tag1, scheme))
            XCTAssertEqual(Set(tones).count, 3, "\(scheme): a family member repeats a tone")
        }
    }

    /// A strand's ancestors come root first, one per indent level, and a top level
    /// strand has none.
    func testAncestorsRunRootFirst() {
        let family = StrandFamily(strands: liveShape, scheme: .light)
        let leaf = liveShape[2]
        XCTAssertEqual(family.ancestors(of: leaf, depth: 2).map(\.slug), ["Tag1", "Jesse"])
        XCTAssertEqual(family.ancestors(of: leaf, depth: 1).map(\.slug), ["Jesse"])
        XCTAssertEqual(family.ancestors(of: liveShape[0], depth: 0), [])
        XCTAssertNil(family.parent(of: liveShape[0]))
        XCTAssertEqual(family.parent(of: liveShape[4])?.title, "Trovato")
    }

    /// A child says where it sits, to a screen reader and in the flat lenses' caption,
    /// right after its title; a root says nothing extra.
    func testAChildSaysItsParent() {
        XCTAssertEqual(StrandsSemantics.parentCaption("Jesse"), "in Jesse")
        let label = StrandsSemantics.rowAccessibilityLabel(liveShape[2], today: "2026-09-26",
                                                           parentTitle: "Jesse")
        XCTAssertTrue(label.hasPrefix("Project: Tag1, Strands System, in Jesse"), label)
        let root = StrandsSemantics.rowAccessibilityLabel(liveShape[0], today: "2026-09-26")
        XCTAssertFalse(root.contains(" in "), root)
    }

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
