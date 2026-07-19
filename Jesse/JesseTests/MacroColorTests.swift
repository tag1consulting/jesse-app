import XCTest
import SwiftUI
import UIKit
@testable import Jesse

// Fiber is a subset of carbs, so its identity color must be a lighter *shade of the
// carbs color* — same hue family, clearly lighter, fully opaque — not an independent
// hue. These resolve the canonical `MacroColor` swatches to concrete components in
// both light and dark mode and lock that relationship in. A regression back to the
// old independent `.brown` fails here (its hue is nowhere near the carbs teal).

@MainActor
final class MacroColorTests: XCTestCase {

    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    private struct HSBA { var h: CGFloat; var s: CGFloat; var b: CGFloat; var a: CGFloat }
    private struct RGBA { var r: CGFloat; var g: CGFloat; var b: CGFloat; var a: CGFloat }

    private func hsba(_ color: Color, _ traits: UITraitCollection) -> HSBA {
        let ui = UIColor(color).resolvedColor(with: traits)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return HSBA(h: h, s: s, b: b, a: a)
    }

    private func rgba(_ color: Color, _ traits: UITraitCollection) -> RGBA {
        let ui = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: r, g: g, b: b, a: a)
    }

    /// Perceptual luminance (Rec. 601), higher = lighter.
    private func luminance(_ c: RGBA) -> CGFloat { 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }

    /// Smallest angular distance between two hues on the [0,1) wheel.
    private func hueDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    private func assertFiberIsAPalerCarb(_ traits: UITraitCollection, _ mode: String) {
        let carbs = hsba(MacroColor.carbs, traits)
        let fiber = hsba(MacroColor.fiber, traits)

        // Same hue family as carbs — a shade of it, not an independent hue.
        XCTAssertLessThan(hueDelta(carbs.h, fiber.h), 0.06,
                          "\(mode): fiber hue \(fiber.h) is not in the carbs teal family \(carbs.h)")
        // Clearly lighter: lightening toward white raises brightness and drops saturation.
        XCTAssertGreaterThan(fiber.b, carbs.b, "\(mode): fiber is not brighter than carbs")
        XCTAssertLessThan(fiber.s, carbs.s, "\(mode): fiber is not less saturated than carbs")
        XCTAssertGreaterThan(luminance(rgba(MacroColor.fiber, traits)),
                             luminance(rgba(MacroColor.carbs, traits)),
                             "\(mode): fiber is not lighter than carbs by luminance")
    }

    func testFiberIsAShadeOfCarbsInLightMode() { assertFiberIsAPalerCarb(light, "light") }
    func testFiberIsAShadeOfCarbsInDarkMode() { assertFiberIsAPalerCarb(dark, "dark") }

    func testFiberStaysOpaqueInBothModes() {
        // The fiber segment sits over other content in the calorie-source bar, so it
        // must never rely on alpha to look paler.
        XCTAssertEqual(rgba(MacroColor.fiber, light).a, 1, accuracy: 0.001)
        XCTAssertEqual(rgba(MacroColor.fiber, dark).a, 1, accuracy: 0.001)
    }

    func testFiberAndCarbsStayDistinguishable() {
        // Paler kin sitting side by side — but still tellable apart at the bar's real
        // height, in both modes. Require a meaningful component distance.
        for (traits, mode) in [(light, "light"), (dark, "dark")] {
            let c = rgba(MacroColor.carbs, traits), f = rgba(MacroColor.fiber, traits)
            let dist = abs(c.r - f.r) + abs(c.g - f.g) + abs(c.b - f.b)
            XCTAssertGreaterThan(dist, 0.15, "\(mode): fiber and carbs are too close to tell apart")
        }
    }

    func testFiberIsNotTheOldBrownHue() {
        // The retired independent hue. Fiber's teal shade must be nowhere near it.
        for (traits, mode) in [(light, "light"), (dark, "dark")] {
            let brown = UIColor.brown.resolvedColor(with: traits)
            var bh: CGFloat = 0, bs: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            brown.getHue(&bh, saturation: &bs, brightness: &bb, alpha: &ba)
            XCTAssertGreaterThan(hueDelta(bh, hsba(MacroColor.fiber, traits).h), 0.15,
                                 "\(mode): fiber still reads as the old brown hue")
        }
    }
}
