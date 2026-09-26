import SwiftUI
import JesseNetworking

// A strand's own tone: its topic's colour, stepped once per level down the strand tree,
// so a family reads as a family. The rule and its contract are stated in the header of
// `TodayProjectPalette.swift`, next to the contract it lives inside; this file is the
// arithmetic.

// MARK: - OKLCH

/// One colour in OKLCH: perceptual lightness (0 to 1), chroma, and hue in degrees.
///
/// OKLCH rather than HSL because equal steps in it LOOK equal. An HSL "lighten" on a blue
/// drifts it toward purple and changes how saturated it reads, so a child one step down
/// would look like a different family rather than a lighter member of the same one.
/// Ottosson's OKLab, in polar form; no dependency, because it is two matrices and a cube
/// root.
public struct OKLCH: Equatable, Sendable {
    public var lightness: Double
    public var chroma: Double
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    /// From an sRGB colour.
    public init(_ colour: TodayProjectColor) {
        let (r, g, b) = (OKLCH.toLinear(colour.red), OKLCH.toLinear(colour.green),
                         OKLCH.toLinear(colour.blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(B, A) * 180 / .pi
        self.init(lightness: L, chroma: (A * A + B * B).squareRoot(),
                  hue: hue < 0 ? hue + 360 : hue)
    }

    /// The colour in LINEAR sRGB, unclamped: a channel outside 0...1 means the colour is
    /// outside the sRGB gamut.
    func linear() -> (Double, Double, Double) {
        let radians = hue * .pi / 180
        let (A, B) = (chroma * cos(radians), chroma * sin(radians))
        let l = pow(lightness + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(lightness - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(lightness - 0.0894841775 * A - 1.2914855480 * B, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Whether this colour can be shown in sRGB at all.
    public var isInGamut: Bool {
        let (r, g, b) = linear()
        let tolerance = 1e-9
        return [r, g, b].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
    }

    /// **The sRGB colour, gamut mapped.** A colour outside sRGB loses chroma, at its own
    /// lightness and hue, until it fits: clipping each channel instead would shift the
    /// hue, which is the one thing a family tone must not do by accident.
    public var sRGB: TodayProjectColor {
        var fitted = self
        if !fitted.isInGamut {
            var (low, high) = (0.0, chroma)
            for _ in 0..<40 {
                fitted.chroma = (low + high) / 2
                if fitted.isInGamut { low = fitted.chroma } else { high = fitted.chroma }
            }
            fitted.chroma = low
        }
        let (r, g, b) = fitted.linear()
        func encode(_ c: Double) -> Double {
            let clamped = min(max(c, 0), 1)
            return clamped <= 0.0031308 ? 12.92 * clamped
                                        : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return TodayProjectColor(red: encode(r), green: encode(g), blue: encode(b))
    }

    static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

extension TodayProjectColor {
    /// WCAG relative luminance.
    var luminance: Double {
        0.2126 * OKLCH.toLinear(red) + 0.7152 * OKLCH.toLinear(green)
            + 0.0722 * OKLCH.toLinear(blue)
    }

    /// The WCAG contrast ratio between two colours.
    public func contrast(with other: TodayProjectColor) -> Double {
        let (x, y) = (luminance, other.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

// MARK: - The derivation

/// How one topic steps down a level, in one appearance. Data, so the numbers the tests
/// measure are the numbers the rows draw.
public struct StrandToneTuning: Equatable, Sendable {
    /// OKLCH lightness per level. Positive lightens. Signed because a topic's
    /// neighbours decide which way it has room: see `StrandTone.tuning`.
    public var lightnessStep: Double
    /// Degrees of hue per slot unit.
    public var hueUnit: Double
    /// The share of chroma a child keeps from its parent.
    public var chromaKeep: Double

    public init(lightnessStep: Double, hueUnit: Double, chromaKeep: Double) {
        self.lightnessStep = lightnessStep
        self.hueUnit = hueUnit
        self.chromaKeep = chromaKeep
    }
}

/// **A strand's tone**: its topic's base colour at the root of its family, and one step
/// per level below it. Pure and total; the rule is documented in the palette's header.
public enum StrandTone {

    /// The deepest level that takes a step of its own. A strand below it wears its
    /// ancestor's tone at this depth: the tests cover every path this deep, and a tone
    /// no test has measured is a tone that may be Network purple.
    public static let maxDepth = 4

    /// The hue offsets a child can take, in hue units, both sides of its parent. A
    /// strand's slot is a hash of its own slug, so siblings fan out around the parent
    /// and a strand's tone never depends on who its siblings are.
    public static let slots: [Double] = [1, -1, 2, -2]

    /// **The step table.** One row per topic and appearance, each the widest sweep that
    /// keeps every tone at every depth and slot at least ΔE 10 from every other topic
    /// under all four visions (asserted in `StrandToneTests`). The palette header says
    /// why some rows darken and some sweep less.
    public static func tuning(_ project: TodayProject, _ scheme: ColorScheme) -> StrandToneTuning {
        let dark = scheme == .dark
        switch project {
        case .tag1:
            return dark ? StrandToneTuning(lightnessStep: 0.05, hueUnit: 6, chromaKeep: 0.96)
                        : StrandToneTuning(lightnessStep: 0.05, hueUnit: 6, chromaKeep: 0.84)
        case .personal:
            return dark ? StrandToneTuning(lightnessStep: 0.07, hueUnit: 6, chromaKeep: 1)
                        : StrandToneTuning(lightnessStep: 0.07, hueUnit: 6, chromaKeep: 0.96)
        case .network:
            // Light: one degree a unit. Network's light purple sits ΔE 17.5 from Tag1's
            // blue under protanopia, and a wider turn toward blue closes that gap.
            return dark ? StrandToneTuning(lightnessStep: 0.05, hueUnit: 4, chromaKeep: 0.80)
                        : StrandToneTuning(lightnessStep: 0.06, hueUnit: 1, chromaKeep: 0.80)
        case .viaConMe:
            // Light: no sweep at all. The orange clears 4.5:1 with little to spare, so
            // lightening stops at the 3:1 floor within two levels; darker walks into
            // Perseido under deuteranopia and any turn walks into Personal under
            // protanopia. Its children step by lightness, then by chroma, and siblings
            // share a tone. Dark: it darkens, because lighter is where Personal is.
            return dark ? StrandToneTuning(lightnessStep: -0.07, hueUnit: 6, chromaKeep: 1)
                        : StrandToneTuning(lightnessStep: 0.08, hueUnit: 0, chromaKeep: 0.84)
        case .perseido:
            // Light: one degree a unit, for the same reason as Via Con Me in miniature.
            // Dark: it darkens, because its light red and Personal's light green are only
            // ΔE 11.5 apart under deuteranopia and lighter closes that gap.
            return dark ? StrandToneTuning(lightnessStep: -0.06, hueUnit: 6, chromaKeep: 1)
                        : StrandToneTuning(lightnessStep: 0.09, hueUnit: 1, chromaKeep: 0.84)
        case .unfiled:
            // A grey has no hue to turn and must never grow one, so a child steps by
            // lightness alone, and toward the side with room: darker in both appearances.
            return dark ? StrandToneTuning(lightnessStep: -0.06, hueUnit: 0, chromaKeep: 1)
                        : StrandToneTuning(lightnessStep: -0.07, hueUnit: 0, chromaKeep: 1)
        }
    }

    /// The lightest a tone may go in the dark appearance: above it everything washes
    /// toward white and the family stops reading as a colour.
    public static let darkCeiling = 0.93

    /// The non text contrast floor every derived tone clears against its background,
    /// with a hair of margin over WCAG's 3:1.
    public static let contrastFloor = 3.05

    /// The backgrounds tones are drawn on: the palette's own.
    public static let lightBackground = TodayProjectColor(hex: 0xFFFFFF)
    public static let darkBackground = TodayProjectColor(hex: 0x1C1C1E)

    /// **The tone for one strand** in one appearance. A slug the snapshot does not hold
    /// has no topic to read and draws the neutral; every strand from a bridge that sends
    /// no `parent` is a root and draws its topic's base.
    public static func color(for slug: String, in snapshot: StrandsSnapshot,
                             scheme: ColorScheme) -> TodayProjectColor {
        color(for: slug, in: snapshot.strands, scheme: scheme)
    }

    /// The same, over a plain list of strands.
    public static func color(for slug: String, in strands: [Strand],
                             scheme: ColorScheme) -> TodayProjectColor {
        let bySlug = index(strands)
        guard let strand = bySlug[slug] else { return base(.unfiled, scheme) }
        return color(path: path(to: strand, in: bySlug), project: strand.group, scheme: scheme)
    }

    /// Every strand's tone at once, by slug: what a board draws from, so a redraw walks
    /// the snapshot once rather than once per row.
    public static func table(for strands: [Strand],
                             scheme: ColorScheme) -> [String: TodayProjectColor] {
        let bySlug = index(strands)
        var out: [String: TodayProjectColor] = [:]
        for strand in bySlug.values {
            out[strand.slug] = color(path: path(to: strand, in: bySlug),
                                     project: strand.group, scheme: scheme)
        }
        return out
    }

    private static func index(_ strands: [Strand]) -> [String: Strand] {
        Dictionary(strands.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The slots from the family's root down to `strand`, root excluded, capped at
    /// `maxDepth` steps. A strand is a root when its parent is absent from the snapshot
    /// or files under a different topic: a Personal strand under a Tag1 parent starts a
    /// Personal family of its own rather than wearing a Tag1 blue.
    static func path(to strand: Strand, in bySlug: [String: Strand]) -> [Double] {
        var slots: [Double] = []
        var seen: Set<String> = [strand.slug]
        var current = strand
        while let parentSlug = current.parent, let parent = bySlug[parentSlug],
              parent.group == current.group, seen.insert(parent.slug).inserted {
            slots.append(slot(for: current.slug))
            current = parent
        }
        // `slots` runs child to root; the walk down from the root takes the first ones.
        return Array(slots.reversed().prefix(maxDepth))
    }

    /// A tone from its topic's base and the slots of the levels below the root.
    public static func color(path: [Double], project: TodayProject,
                             scheme: ColorScheme) -> TodayProjectColor {
        color(path: path, base: base(project, scheme), tuning: tuning(project, scheme),
              scheme: scheme)
    }

    /// The same, from any base and tuning: what the tuning search measures.
    public static func color(path: [Double], base: TodayProjectColor,
                             tuning: StrandToneTuning, scheme: ColorScheme) -> TodayProjectColor {
        // A root draws the table's value itself, not a round trip of it, so a root
        // strand and a Today item of the same topic match to the last bit.
        guard !path.isEmpty else { return base }
        var tone = OKLCH(base)
        for slot in path {
            tone = step(tone, slot: slot, tuning: tuning, scheme: scheme)
        }
        return tone.sRGB
    }

    /// **One level down.** One lightness step, a little less chroma, and turned by the
    /// slot's hue offset. When the lightness step cannot be taken in full (the contrast
    /// floor, or the dark appearance's ceiling) the part that could not be spent on
    /// lightness goes to the hue instead, so a deep child still differs from its parent
    /// by about as much as a shallow one does.
    static func step(_ parent: OKLCH, slot: Double, tuning: StrandToneTuning,
                     scheme: ColorScheme) -> OKLCH {
        let dL = tuning.lightnessStep
        var child = parent
        child.chroma = parent.chroma * tuning.chromaKeep
        child.hue = wrap(parent.hue + slot * tuning.hueUnit)
        child.lightness = furthestLightness(from: parent.lightness, toward: parent.lightness + dL,
                                            shape: child, scheme: scheme)
        let unspent = dL == 0 ? 0 : 1 - (child.lightness - parent.lightness) / dL
        if unspent > 1e-9, tuning.hueUnit > 0 {
            child.hue = wrap(child.hue + slot * tuning.hueUnit * unspent)
            // The turn can move the contrast a hair; settle the lightness again at the
            // final hue, never past where it already stopped.
            child.lightness = furthestLightness(from: parent.lightness, toward: child.lightness,
                                                shape: child, scheme: scheme)
        }
        return child
    }

    /// The lightness furthest along `from` to `toward` at which `shape` (its chroma and
    /// hue) still clears the contrast floor and, in the dark, the ceiling.
    static func furthestLightness(from start: Double, toward end: Double, shape: OKLCH,
                                  scheme: ColorScheme) -> Double {
        let background = scheme == .dark ? darkBackground : lightBackground
        func fits(_ lightness: Double) -> Bool {
            var probe = shape
            probe.lightness = lightness
            if scheme == .dark, lightness > darkCeiling { return false }
            return probe.sRGB.contrast(with: background) >= contrastFloor
        }
        if fits(end) { return end }
        guard fits(start) else { return start }
        var (good, bad) = (start, end)
        for _ in 0..<40 {
            let mid = (good + bad) / 2
            if fits(mid) { good = mid } else { bad = mid }
        }
        return good
    }

    /// A strand's slot: FNV 1a over the slug's UTF 8 bytes, modulo the slot count. Not
    /// Swift's `hashValue`, which is seeded per launch and would repaint the board every
    /// time the app started.
    public static func slot(for slug: String) -> Double {
        slots[Int(fnv1a(slug) % UInt32(slots.count))]
    }

    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    static func wrap(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    static func base(_ project: TodayProject, _ scheme: ColorScheme) -> TodayProjectColor {
        let role = TodayProjectPalette.role(for: project)
        return scheme == .dark ? role.dark : role.light
    }
}

// MARK: - A board's families

/// **Everything a board needs to draw strand families**, built once per redraw from the
/// snapshot: each strand's tone in the current appearance, and who its parent is.
///
/// Built from the WHOLE snapshot rather than from the rows a lens shows, so a tone never
/// depends on the lens, on what is collapsed, or on whether the parent is dormant.
public struct StrandFamily: Sendable {
    private let bySlug: [String: Strand]
    private let tones: [String: TodayProjectColor]
    private let scheme: ColorScheme

    public init(strands: [Strand], scheme: ColorScheme) {
        self.scheme = scheme
        bySlug = Dictionary(strands.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        tones = StrandTone.table(for: strands, scheme: scheme)
    }

    /// The strand's tone; a slug this board does not hold draws the neutral.
    public func tone(_ slug: String) -> TodayProjectColor {
        tones[slug] ?? StrandTone.base(.unfiled, scheme)
    }

    /// The strand this one sits under, when the snapshot holds it. Any topic: a caption
    /// that says `in Trovato` is true whatever colour either strand wears.
    public func parent(of strand: Strand) -> Strand? {
        guard let slug = strand.parent, slug != strand.slug else { return nil }
        return bySlug[slug]
    }

    /// The `depth` strands above this one, nearest last: what the `Tree` lens draws a
    /// rail for at each indent level. Shorter than `depth` only for a chain the snapshot
    /// cannot finish, in which case the missing rails are simply not drawn.
    public func ancestors(of strand: Strand, depth: Int) -> [Strand] {
        var chain: [Strand] = []
        var current = strand
        while chain.count < depth, let parent = parent(of: current),
              !chain.contains(where: { $0.slug == parent.slug }) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }
}
