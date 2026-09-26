import SwiftUI
import JesseNetworking

// A strand's own tone: its ROOT STRAND's colour, stepped once per level down the strand
// tree, so a family reads as a family and two families never read as one. The rule and
// its contract are stated in the header of `TodayProjectPalette.swift`, next to the
// contract it lives inside; this file is the table and the arithmetic.

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

/// **One family's colour**: a hue, and where on the lightness axis that family's ROOT
/// sits in each appearance. Data, so the numbers the tests measure are the numbers the
/// rows draw.
///
/// The hue is shared by both appearances and the lightness and chroma are not: a family
/// keeps its identity between light and dark (Trovato is teal in both), while each
/// appearance puts the root where that appearance has room to step away from it.
public struct StrandToneSlot: Equatable, Sendable {
    /// OKLCH hue in degrees. One value, both appearances.
    public var hue: Double
    /// The root's OKLCH lightness and chroma in the light appearance.
    public var lightLightness: Double
    public var lightChroma: Double
    /// The same in the dark appearance.
    public var darkLightness: Double
    public var darkChroma: Double

    public init(hue: Double, lightLightness: Double, lightChroma: Double,
                darkLightness: Double, darkChroma: Double) {
        self.hue = hue
        self.lightLightness = lightLightness
        self.lightChroma = lightChroma
        self.darkLightness = darkLightness
        self.darkChroma = darkChroma
    }

    /// The root's colour in one appearance, in OKLCH.
    public func root(_ scheme: ColorScheme) -> OKLCH {
        scheme == .dark ? OKLCH(lightness: darkLightness, chroma: darkChroma, hue: hue)
                        : OKLCH(lightness: lightLightness, chroma: lightChroma, hue: hue)
    }
}

/// **A strand's tone**: its ROOT STRAND's own colour, stepped once per level down to it.
/// Pure and total; the rule is documented in the palette's header.
public enum StrandTone {

    /// The deepest level that takes a step of its own. A strand below it wears its
    /// ancestor's tone at this depth: the tests cover every level this deep, and a tone
    /// no test has measured is a tone that may be somebody else's family.
    public static let maxDepth = 3

    /// **The root table.** One slot per top level strand, keyed by its slug LOWERCASED
    /// (the bridge sends `Via-Con-Me`; the table reads `via-con-me`, so the two spellings
    /// cannot disagree). Eight entries, the eight roots the vault holds, each its own
    /// colour rather than its topic's — the fault this table exists to fix is that five
    /// topics cannot tell eight roots apart.
    ///
    /// The values were searched, not chosen by eye, against the four properties
    /// `StrandToneTests` asserts; the four that had a topic colour before kept its
    /// family (Tag1 blue, Homelab purple, Perseido red, Via Con Me orange).
    public static let roots: [String: StrandToneSlot] = [
        "perseido":   StrandToneSlot(hue:  24.0, lightLightness: 0.540, lightChroma: 0.198,
                                     darkLightness: 0.587, darkChroma: 0.168),
        "via-con-me": StrandToneSlot(hue:  50.4, lightLightness: 0.620, lightChroma: 0.132,
                                     darkLightness: 0.530, darkChroma: 0.128),
        "tangent":    StrandToneSlot(hue:  95.1, lightLightness: 0.606, lightChroma: 0.221,
                                     darkLightness: 0.600, darkChroma: 0.187),
        "family":     StrandToneSlot(hue: 153.9, lightLightness: 0.545, lightChroma: 0.124,
                                     darkLightness: 0.554, darkChroma: 0.111),
        "trovato":    StrandToneSlot(hue: 198.3, lightLightness: 0.588, lightChroma: 0.106,
                                     darkLightness: 0.530, darkChroma: 0.238),
        "tag1":       StrandToneSlot(hue: 241.4, lightLightness: 0.601, lightChroma: 0.167,
                                     darkLightness: 0.583, darkChroma: 0.240),
        "homelab":    StrandToneSlot(hue: 301.9, lightLightness: 0.540, lightChroma: 0.231,
                                     darkLightness: 0.530, darkChroma: 0.120),
        "health":     StrandToneSlot(hue: 352.0, lightLightness: 0.607, lightChroma: 0.240,
                                     darkLightness: 0.576, darkChroma: 0.172),
    ]

    /// **The four spare slots**, for a root the table has never heard of. Their hues sit
    /// in the four widest gaps the eight leave, so a new root is at least ΔE 12 from
    /// every named one rather than a repeat of it — a weaker promise than the ΔE 20 the
    /// eight keep between themselves, and deliberately so: twelve hues cannot all be
    /// twenty apart, and the eight that exist are the ones that must be.
    public static let spares: [StrandToneSlot] = [
        StrandToneSlot(hue: 138.2, lightLightness: 0.600, lightChroma: 0.202,
                       darkLightness: 0.560, darkChroma: 0.206),
        StrandToneSlot(hue: 174.8, lightLightness: 0.600, lightChroma: 0.126,
                       darkLightness: 0.624, darkChroma: 0.238),
        StrandToneSlot(hue: 222.4, lightLightness: 0.600, lightChroma: 0.130,
                       darkLightness: 0.576, darkChroma: 0.254),
        StrandToneSlot(hue: 264.0, lightLightness: 0.600, lightChroma: 0.198,
                       darkLightness: 0.560, darkChroma: 0.250),
    ]

    /// **What one level down costs, in OKLCH lightness.** Signed, and the sign is the
    /// whole of it: in the light appearance a child DARKENS and in the dark appearance it
    /// LIGHTENS, because that is the direction each appearance has room in. Lightening on
    /// white walks into the 3:1 floor within a level and a half; darkening on `#1C1C1E`
    /// does the same. Both directions therefore move AWAY from the background, and a
    /// deeper strand is a stronger mark rather than a fainter one.
    ///
    /// The magnitudes are the smallest that keep every level at least ΔE*ab 12 from the
    /// level above it at every hue in the table — including teal, which has the least
    /// chroma to spare and so sets the floor.
    public static func step(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.108 : -0.100
    }

    /// The non text contrast floor every tone in the table clears against its background,
    /// with a hair of margin over WCAG's 3:1. Asserted, not enforced at runtime: these
    /// are fixed values, so a tone that fails is a test failure rather than something to
    /// clamp behind Jeremy's back.
    public static let contrastFloor = 3.05

    /// The backgrounds tones are drawn on: the palette's own.
    public static let lightBackground = TodayProjectColor(hex: 0xFFFFFF)
    public static let darkBackground = TodayProjectColor(hex: 0x1C1C1E)

    /// The tone a strand draws when its family cannot be resolved at all — a slug the
    /// board does not hold. A grey, so "no family" reads as an absence.
    public static func neutral(_ scheme: ColorScheme) -> TodayProjectColor {
        let role = TodayProjectPalette.role(for: .unfiled)
        return scheme == .dark ? role.dark : role.light
    }

    // MARK: Resolving one strand

    /// **The tone for one strand** in one appearance. A slug the snapshot does not hold
    /// draws the neutral; every strand from a bridge that sends no `parent` is a root and
    /// draws its own slot.
    public static func color(for slug: String, in snapshot: StrandsSnapshot,
                             scheme: ColorScheme) -> TodayProjectColor {
        color(for: slug, in: snapshot.strands, scheme: scheme)
    }

    /// The same, over a plain list of strands.
    public static func color(for slug: String, in strands: [Strand],
                             scheme: ColorScheme) -> TodayProjectColor {
        let bySlug = index(strands)
        guard let strand = bySlug[slug] else { return neutral(scheme) }
        let family = family(of: strand, in: bySlug)
        return color(root: family.root, depth: family.depth, scheme: scheme)
    }

    /// Every strand's tone at once, by slug: what a board draws from, so a redraw walks
    /// the snapshot once rather than once per row.
    public static func table(for strands: [Strand],
                             scheme: ColorScheme) -> [String: TodayProjectColor] {
        let bySlug = index(strands)
        var out: [String: TodayProjectColor] = [:]
        for strand in bySlug.values {
            let family = family(of: strand, in: bySlug)
            out[strand.slug] = color(root: family.root, depth: family.depth, scheme: scheme)
        }
        return out
    }

    private static func index(_ strands: [Strand]) -> [String: Strand] {
        Dictionary(strands.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// **Which family a strand belongs to, and how far down it sits.** The walk is
    /// STRUCTURAL and nothing else: it follows `parent` to the top of the chain, whatever
    /// topics it passes through, because a strand's colour is its family's and a family is
    /// not a topic. A strand whose parent the snapshot does not hold is its own root, and
    /// so is one whose chain loops (the guard the bridge's own resolver leaves to the
    /// client). Depth is edges from the root, capped at `maxDepth`.
    static func family(of strand: Strand, in bySlug: [String: Strand]) -> (root: String, depth: Int) {
        var depth = 0
        var seen: Set<String> = [strand.slug]
        var current = strand
        while let parentSlug = current.parent, let parent = bySlug[parentSlug],
              seen.insert(parent.slug).inserted {
            depth += 1
            current = parent
        }
        return (current.slug, min(depth, maxDepth))
    }

    /// **A tone, from its root's slug and its depth below that root.** The one place a
    /// strand's colour is computed: the board's rows, the flat lenses' `in <parent>` dot
    /// and the table above all end up here.
    public static func color(root: String, depth: Int,
                             scheme: ColorScheme) -> TodayProjectColor {
        let slot = slot(forRoot: root)
        var tone = slot.root(scheme)
        // A root draws its slot's own value, not a round trip of it.
        guard depth > 0 else { return tone.sRGB }
        tone.lightness += Double(min(depth, maxDepth)) * step(scheme)
        return tone.sRGB
    }

    /// The slot a root slug takes: its own if the table names it, otherwise one of the
    /// four spares chosen by FNV 1a over the slug's UTF 8 bytes. Not Swift's `hashValue`,
    /// which is seeded per launch and would repaint the board every time the app started.
    public static func slot(forRoot slug: String) -> StrandToneSlot {
        if let named = roots[slug.lowercased()] { return named }
        return spares[Int(fnv1a(slug.lowercased()) % UInt32(spares.count))]
    }

    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
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
        tones[slug] ?? StrandTone.neutral(scheme)
    }

    /// The strand this one sits under, when the snapshot holds it. Any topic: a caption
    /// that says `in Trovato` is true whatever colour either strand wears.
    public func parent(of strand: Strand) -> Strand? {
        guard let slug = strand.parent, slug != strand.slug else { return nil }
        return bySlug[slug]
    }
}
