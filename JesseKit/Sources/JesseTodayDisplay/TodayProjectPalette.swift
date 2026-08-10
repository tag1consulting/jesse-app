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
