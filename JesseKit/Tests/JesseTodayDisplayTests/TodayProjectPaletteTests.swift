import XCTest
@testable import JesseTodayDisplay
import JesseNetworking

// The project palette, measured rather than admired.
//
// A colour table is the kind of thing that is "obviously fine" the day it is written
// and quietly illegible three edits later, because nothing about looking at a swatch
// tells you its contrast ratio or what it becomes for a red-green colourblind reader.
// So the two properties the palette exists to have are asserted here, over the exact
// values in the table:
//
//   1. **Legible in both appearances** — at least 4.5:1 against its own background
//      (white for light, `#1C1C1E` for dark). That is the WCAG threshold for TEXT, not
//      the looser 3:1 one for UI components, because these colours also tint small
//      labels.
//   2. **Distinguishable, including under colour blindness** — every PAIR of roles at
//      least ΔE*ab 10 apart under normal vision and under simulated protanopia,
//      deuteranopia and tritanopia. Ten is a conservative "clearly a different colour"
//      for the small filled shapes these are used as.
//
// The simulation is done here rather than trusted from a design tool, so a future edit
// to a hue is checked by the suite rather than by whoever remembers to re-check.
//
// If a hue change fails one of these, the change is wrong — not the test. The slugs are
// frozen wire; the hues are a design choice that has to keep clearing this bar.

final class TodayProjectPaletteTests: XCTestCase {

    // MARK: - Completeness

    /// Every slug has a role, and the table is exhaustive by construction (the `switch`
    /// has no `default`). This asserts the other half: that `roles` really does carry
    /// all of them, in Dashboard order.
    func testEverySlugHasARole() {
        XCTAssertEqual(TodayProjectPalette.roles.map(\.project), TodayProject.allCases)
        for project in TodayProject.allCases {
            let role = TodayProjectPalette.role(for: project)
            XCTAssertEqual(role.project, project)
            XCTAssertFalse(role.label.isEmpty, "\(project) has no label")
            XCTAssertFalse(role.symbol.isEmpty, "\(project) has no symbol")
            XCTAssertFalse(role.accessibilityLabel.isEmpty,
                           "\(project) would be silent to VoiceOver")
        }
    }

    /// The role for an item is the role for its slug — the one lookup a row makes.
    func testAnItemResolvesToItsProjectsRole() {
        let item = TodayItem(id: "a", lead: "x", project: .perseido)
        XCTAssertEqual(TodayProjectPalette.role(for: item).project, .perseido)
        XCTAssertEqual(TodayProjectPalette.role(for: item), TodayProjectPalette.role(for: .perseido))
    }

    /// **`unfiled` is a NEUTRAL, in both appearances.** "No project" has to read as an
    /// absence; a sixth hue would present the large minority of unfiled items as a sixth
    /// project, which is precisely the reading the bridge's own docs warn against.
    func testUnfiledIsNeutralAndIsTheOnlyNeutral() {
        let unfiled = TodayProjectPalette.role(for: .unfiled)
        XCTAssertTrue(unfiled.isNeutral)
        XCTAssertTrue(unfiled.light.isNeutral, "a grey has no hue: r == g == b")
        XCTAssertTrue(unfiled.dark.isNeutral)
        for project in TodayProject.filed {
            XCTAssertFalse(TodayProjectPalette.role(for: project).isNeutral,
                           "\(project) is a real project and must carry a hue")
        }
    }

    /// Light and dark are genuinely different values. A single value used for both is
    /// the failure this pair exists to prevent — it is always illegible on one of them.
    func testEveryRoleHasDistinctLightAndDarkValues() {
        for role in TodayProjectPalette.roles {
            XCTAssertNotEqual(role.light, role.dark, "\(role.project) uses one value for both")
        }
    }

    // MARK: - Legibility

    func testEveryColourClearsTextContrastAgainstItsOwnBackground() {
        let lightBG = TodayProjectColor(hex: 0xFFFFFF)
        // The system's dark background, which is what these are drawn on.
        let darkBG = TodayProjectColor(hex: 0x1C1C1E)
        for role in TodayProjectPalette.roles {
            let light = contrast(role.light, lightBG)
            let dark = contrast(role.dark, darkBG)
            XCTAssertGreaterThanOrEqual(light, 4.5,
                                        "\(role.project) light is \(fmt(light)):1 on white")
            XCTAssertGreaterThanOrEqual(dark, 4.5,
                                        "\(role.project) dark is \(fmt(dark)):1 on #1C1C1E")
        }
    }

    // MARK: - Distinguishability

    func testEveryPairStaysApartUnderNormalAndColourblindVision() {
        for (name, table) in [("light", TodayProjectPalette.roles.map(\.light)),
                              ("dark", TodayProjectPalette.roles.map(\.dark))] {
            for vision in Vision.allCases {
                for i in table.indices {
                    for j in table.indices where j > i {
                        let d = deltaE(vision.apply(table[i]), vision.apply(table[j]))
                        let pair = "\(TodayProjectPalette.roles[i].project) vs "
                            + "\(TodayProjectPalette.roles[j].project)"
                        XCTAssertGreaterThanOrEqual(
                            d, 10,
                            "\(name)/\(vision): \(pair) are ΔE \(fmt(d)) apart — too close")
                    }
                }
            }
        }
    }

    // MARK: - Colour maths
    //
    // sRGB → linear → CIEXYZ → CIELAB, plus the Machado/Viénot-style linear-RGB matrices
    // for the three dichromacies. Small, standard, and here rather than in the source
    // because nothing the app draws needs it — only this measurement does.

    /// sRGB component → linear. A free function so both the contrast maths and the
    /// dichromacy simulation (which lives on the nested enum) can reach it.
    private static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private enum Vision: String, CaseIterable, CustomStringConvertible {
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

        /// The colour as this vision sees it, in LINEAR rgb.
        func apply(_ colour: TodayProjectColor) -> [Double] {
            let v = [TodayProjectPaletteTests.toLinear(colour.red),
                     TodayProjectPaletteTests.toLinear(colour.green),
                     TodayProjectPaletteTests.toLinear(colour.blue)]
            guard let m = matrix else { return v }
            var out: [Double] = []
            for row in m {
                var sum = 0.0
                for i in 0..<3 { sum += row[i] * v[i] }
                out.append(sum)
            }
            return out
        }
    }

    private func linear(_ c: TodayProjectColor) -> [Double] {
        [Self.toLinear(c.red), Self.toLinear(c.green), Self.toLinear(c.blue)]
    }

    private func luminance(_ c: TodayProjectColor) -> Double {
        let v = linear(c)
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    }

    private func contrast(_ a: TodayProjectColor, _ b: TodayProjectColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
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

    private func deltaE(_ a: [Double], _ b: [Double]) -> Double {
        let (la, lb) = (lab(a), lab(b))
        return sqrt(zip(la, lb).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
}
