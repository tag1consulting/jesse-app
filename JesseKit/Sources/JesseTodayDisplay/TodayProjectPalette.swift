import SwiftUI
import JesseNetworking

// **The one project colour table.** Every platform, every surface — a row's dot, the
// detail sheet's accent, a future filter bar, a widget — resolves its colour here and
// nowhere else. A view that writes `.blue` for Tag1 has forked the taxonomy, and the
// second fork is the one that disagrees with the first on a phone in the dark.
//
// The bridge sends the SLUG ONLY and says so in its own docs: "the colour, label and
// ordering a client draws from it are a client concern, and putting any of them on the
// wire would freeze a rendering decision into the API". This file is that client
// concern, in one place.
//
// ## Why literal sRGB values and not `.blue` / `.green` / `.purple`
//
// The system semantic colours adapt to light and dark for free, which is genuinely
// attractive, but they are tuned to be *pleasant*, not to be *told apart*: `.blue`,
// `.indigo` and `.purple` collapse into one another under deuteranopia, and the
// palette's whole job is to survive that. So each role carries an explicit pair — one
// value for light, one for dark — chosen so that:
//
//   * every colour clears **4.5:1** contrast against its own background (white for
//     light, `#1C1C1E` for dark), the text-grade threshold rather than the 3:1
//     non-text one, because these also tint small labels; and
//   * every PAIR of roles stays at least **ΔE*ab 10** apart under normal vision AND
//     under simulated protanopia, deuteranopia and tritanopia.
//
// Both properties are asserted in `TodayProjectPaletteTests`, over these exact values,
// with the simulation done in the test rather than trusted from a design tool. Change
// a hue and that test tells you whether the change is still legible; it is the reason
// the numbers live here as data instead of scattered across views.
//
// Colour is never the only cue. Every surface that uses one of these also carries the
// project's NAME (a chip's label, a sheet's caption, the accessibility label), because
// a palette that is merely colourblind-*safe* still says nothing to a screen reader.
//
// The hues themselves are a design choice and Jeremy should feel free to move them:
// the slugs are frozen wire, the colours are not. What must survive an edit is the two
// properties above.
//
// ## Strand family tones
//
// A strand does NOT wear its topic's colour, and that is the whole of the rule. It wears
// its FAMILY's colour (`StrandTone`), keyed on the slug of the root strand it hangs
// under. Five topics cannot tell eight roots apart: while a root took its topic's base,
// Family and Trovato were the same green and Health and Tangent were the same green as
// each other, because all four file under Personal.
//
//   * **A root strand is a colour of its own.** `StrandTone.roots` holds one slot per top
//     level strand, keyed by its slug lowercased, each with a hue and a root lightness
//     and chroma per appearance. Eight slots for the eight roots the vault holds; the four
//     that had a topic colour kept its family (Tag1 blue, Homelab purple, Perseido red,
//     Via Con Me orange), and Family, Trovato, Health and Tangent gained green, teal,
//     pink and gold. A root the table does not name takes one of four SPARE slots by
//     FNV 1a over its slug (never the per launch seeded `hashValue`), so an unknown root
//     still gets a colour and keeps it when other strands come and go.
//   * **A child is its root's hue, stepped by depth.** Same hue, same chroma, one
//     lightness step per level: DARKER in the light appearance, LIGHTER in the dark one,
//     which in both cases is away from the background, because that is the only direction
//     with room before the 3:1 floor. Siblings at one depth share a tone — their names
//     tell them apart — so a tone never depends on who a strand's siblings are, on the
//     lens, or on what is collapsed. Stepping stops at the third level below the root and
//     anything deeper wears the third level's tone.
//   * **A hue that does not move is what keeps a family in its lane.** Roots differ
//     almost entirely in hue and chroma and a child moves almost entirely in lightness,
//     so a child is further from every other root than from its own by construction, not
//     by luck. It is asserted anyway.
//   * **OKLCH, not HSL**, because equal steps in it look equal: an HSL lighten drifts
//     blue toward purple, and a family would stop reading as a family.
//   * **One bar per row.** A strand's tone is drawn once on a row, as the accent bar, in
//     every lens. The `Tree` lens used to draw a rail per ancestor level in the disclosure
//     column as well; two parallel lines a few points apart read as a mistake, and the
//     indent already says the same thing. See `StrandsListView.treeRow`.
//
// Tones are only ever NON TEXT marks (the row's bar, the caption's dot), so their floor
// is the 3:1 non text threshold; text keeps the topic base and its 4.5:1. `StrandToneTests`
// walks every level to the third in both appearances and asserts that every tone clears
// 3:1 against its background, that every pair of the eight named ROOTS is at least ΔE*ab
// 20 apart under normal vision, that each level is at least ΔE*ab 12 from the level above
// it, and that every child is closer to its own root than to any other. Colour vision
// deficiency is MEASURED and PRINTED rather than gated: eight hues cannot all survive
// deuteranopia, and the strand's name is on every row that carries a tone. Colour is
// still never the only cue — the `Tree` lens draws the relation as indentation, the flat
// lenses caption it `in <parent>`, and VoiceOver says the same.
//
// Two surfaces name a strand and deliberately draw NO tone. A Today row's strand chip
// (`TodayStrandChip`) has only the slug and title the day file carries, not the strands
// snapshot, so it cannot know the family the slug belongs to and draws the tint instead;
// the Vault tab's strand rows are `JesseVault`'s, and that target depends on nothing in
// this one, by design. Both carry the strand's NAME, which is the cue that matters.

// MARK: - A colour, as data

/// One sRGB colour as plain numbers, so the table is testable without rendering
/// anything. `Color` is opaque — you cannot ask it for its components — and a palette
/// nobody can measure is a palette that quietly drifts out of legibility.
public struct TodayProjectColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From a `0xRRGGBB` literal, which is how the table below reads.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// The SwiftUI colour. `.sRGB` explicitly: the values above are sRGB, and letting
    /// the default colour space decide would move them on one platform and not the
    /// other.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// A neutral has no hue at all — the property `unfiled` must keep, since "no
    /// project" has to read as an absence rather than as a sixth project.
    public var isNeutral: Bool { red == green && green == blue }
}

// MARK: - A resolved role

/// Everything a view needs to draw one project, resolved. Call sites take a ROLE, never
/// a raw colour: a `Color` on its own carries no name, and a chip drawn from one is a
/// chip a screen reader reads as nothing.
public struct TodayProjectRole: Equatable, Hashable, Sendable, Identifiable {
    public var project: TodayProject
    /// The display name, spelled as the vault's Dashboard page spells it.
    public var label: String
    /// What VoiceOver says. Prefixed, because "Tag1" alone next to a task reads as part
    /// of the task.
    public var accessibilityLabel: String
    /// The glyph a compact surface uses when there is no room for the label.
    public var symbol: String
    public var light: TodayProjectColor
    public var dark: TodayProjectColor

    public var id: TodayProject { project }

    /// The colour for one appearance. Taking the scheme as an argument (rather than
    /// reading the environment) keeps this type pure and testable; views pass
    /// `@Environment(\.colorScheme)`.
    public func color(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? dark : light).color
    }

    /// Whether this role stands for the ABSENCE of a project. Both of its colours are
    /// greys, and nothing should draw it as an accent.
    public var isNeutral: Bool { light.isNeutral && dark.isNeutral }
}

// MARK: - The table

public enum TodayProjectPalette {

    /// Every role, in Dashboard order (`unfiled` last).
    public static let roles: [TodayProjectRole] = TodayProject.allCases.map(role(for:))

    /// The role for one slug. Total by construction — a `switch` with no `default`, so
    /// adding a slug to the wire enum fails to compile here rather than rendering the
    /// new project as whatever the fallback happened to be.
    public static func role(for project: TodayProject) -> TodayProjectRole {
        switch project {
        case .tag1:
            return TodayProjectRole(
                project: project, label: "Tag1",
                accessibilityLabel: "Project: Tag1", symbol: "building.2",
                light: TodayProjectColor(hex: 0x0B62C4), dark: TodayProjectColor(hex: 0x64B5F6))
        case .personal:
            return TodayProjectRole(
                project: project, label: "Personal",
                accessibilityLabel: "Project: Personal", symbol: "house",
                light: TodayProjectColor(hex: 0x1B7A3E), dark: TodayProjectColor(hex: 0x98D98E))
        case .network:
            return TodayProjectRole(
                project: project, label: "Network",
                accessibilityLabel: "Project: Network", symbol: "network",
                light: TodayProjectColor(hex: 0x6A1B9A), dark: TodayProjectColor(hex: 0xD68FCF))
        case .viaConMe:
            return TodayProjectRole(
                project: project, label: "Via Con Me",
                accessibilityLabel: "Project: Via Con Me", symbol: "car",
                light: TodayProjectColor(hex: 0xB45F06), dark: TodayProjectColor(hex: 0xE9A94F))
        case .perseido:
            return TodayProjectRole(
                project: project, label: "Perseido",
                accessibilityLabel: "Project: Perseido", symbol: "antenna.radiowaves.left.and.right",
                light: TodayProjectColor(hex: 0xAD1F1F), dark: TodayProjectColor(hex: 0xF27C72))
        case .unfiled:
            // A GREY, and the only one. "No project" is an absence, so it is drawn as
            // the lack of a hue rather than as a sixth colour competing with five real
            // ones — on the live day file this is a large minority of items, and a
            // vivid colour on all of them would drown the five that mean something.
            return TodayProjectRole(
                project: project, label: "No project",
                accessibilityLabel: "No project", symbol: "circle.dashed",
                light: TodayProjectColor(hex: 0x6E6E6E), dark: TodayProjectColor(hex: 0xAEAEAE))
        }
    }

    /// The role for an item.
    public static func role(for item: TodayItem) -> TodayProjectRole {
        role(for: item.project)
    }

    /// **What a task row is striped with.** One function so the row accent, and
    /// anything else that wants the same edge, cannot disagree about how loud an
    /// `unfiled` item should be.
    public static func rowAccent(for project: TodayProject) -> TodayRowAccent {
        let role = role(for: project)
        // A real project is drawn at full strength; `unfiled` is drawn FAINT, not
        // merely grey. On the live day file a large minority of items are unfiled, and
        // a solid grey rule down all of them would be the most repeated mark on the
        // screen — the eye would learn to read the stripe as decoration and stop
        // seeing the five that carry meaning.
        return TodayRowAccent(role: role, opacity: role.isNeutral ? 0.25 : 1)
    }
}

// MARK: - The row accent

/// The stripe down a task row's leading edge, as data.
///
/// Data rather than a `View` so the palette stays measurable: `Color` is opaque and a
/// test cannot ask one what it is, which is how a stripe quietly ends up the same hue
/// for two projects. Views render it through `TodayProjectAccentBar`.
public struct TodayRowAccent: Equatable, Hashable, Sendable {
    public var role: TodayProjectRole
    /// How strongly to draw it. See `TodayProjectPalette.rowAccent(for:)`.
    public var opacity: Double

    public init(role: TodayProjectRole, opacity: Double) {
        self.role = role
        self.opacity = opacity
    }

    /// Whether this accent stands for the ABSENCE of a project.
    public var isNeutral: Bool { role.isNeutral }

    public func color(_ scheme: ColorScheme) -> Color { role.color(scheme) }
}

/// A project as a rule down the leading edge of a row.
///
/// A RULE, not a fill. A washed row background is what pushes body text under the
/// contrast threshold the palette was chosen to clear, and it would have to wash an
/// unfiled row grey — which reads as disabled. The same decision the detail view's
/// header made, for the same reason.
///
/// Deliberately invisible to VoiceOver. The project's NAME is already on the row (the
/// caption under the text), and a stripe that also announced it would make every row
/// say its project twice. Colour is never the only cue here; it is the SECOND cue.
public struct TodayProjectAccentBar: View {
    @Environment(\.colorScheme) private var scheme
    /// A Today row's topic accent. Nil on a strand row, which wears its family's tone
    /// and has no topic in its bar at all.
    private let accent: TodayRowAccent?
    /// A strand's family tone, already resolved for the current appearance by
    /// `StrandTone`. Nil on a Today row, which wears its topic.
    private let tone: TodayProjectColor?

    public init(project: TodayProject) {
        self.accent = TodayProjectPalette.rowAccent(for: project)
        self.tone = nil
    }

    /// A strand's bar: the same shape and width as a Today row's, in the tone
    /// `StrandTone` derived for its family. The caller resolves the tone for the
    /// appearance it is drawing in; nothing here computes a colour.
    ///
    /// Always FULL strength, and it takes no project. A Today row draws `unfiled` faint
    /// because "no project" is an absence; a strand's colour comes from its family and
    /// never from its topic, so there is no absence to draw faint — a strand filed under
    /// no project still belongs to a family with a colour of its own.
    public init(strandTone: TodayProjectColor) {
        self.accent = nil
        self.tone = strandTone
    }

    public var body: some View {
        Capsule()
            .fill(tone?.color ?? accent?.color(scheme) ?? Color.clear)
            .opacity(accent?.opacity ?? 1)
            .frame(width: 3)
            .accessibilityHidden(true)
    }
}

// MARK: - The two shared views

/// A project as a small filled dot — the row-level cue, where a full chip would cost
/// more width than the project is worth. Never the only cue: it carries the project's
/// name as its accessibility label, and rows that show it also keep the name available
/// in the item's menu.
public struct TodayProjectDot: View {
    @Environment(\.colorScheme) private var scheme
    private let role: TodayProjectRole

    public init(project: TodayProject) {
        self.role = TodayProjectPalette.role(for: project)
    }

    public var body: some View {
        Circle()
            .fill(role.color(scheme))
            // An unfiled item gets a hollow ring rather than a filled grey dot, so the
            // absence of a project reads as an absence at a glance and not as "grey is
            // a project".
            .opacity(role.isNeutral ? 0.35 : 1)
            .frame(width: 8, height: 8)
            .accessibilityLabel(role.accessibilityLabel)
    }
}

/// A project as a labelled chip — dot plus name. What a detail view and a grouped
/// section header use, where the name is worth its width.
public struct TodayProjectChip: View {
    @Environment(\.colorScheme) private var scheme
    private let role: TodayProjectRole

    public init(project: TodayProject) {
        self.role = TodayProjectPalette.role(for: project)
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(role.color(scheme))
                .opacity(role.isNeutral ? 0.35 : 1)
                .frame(width: 7, height: 7)
            Text(role.label)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(role.isNeutral ? AnyShapeStyle(.secondary)
                                        : AnyShapeStyle(role.color(scheme)))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.accessibilityLabel)
    }
}
