import Foundation

/// The project a day-file item belongs to, as the bridge derived it.
///
/// **A closed set, deliberately.** `bridge/src/today.rs` documents `PROJECT_SLUGS` as
/// "the frozen wire set … the app's decoder is entitled to treat it as closed", and the
/// five topics are the five `Dashboard/<Topic>.md` pages the vault has had for years.
/// So this is an enum rather than a `String` — unlike `TodayLink.kind`, which stays a
/// string precisely because the bridge may extend it.
///
/// Closed is not the same as brittle. A slug this build has never heard of decodes to
/// `.unfiled` rather than throwing: a bridge that grows a sixth topic must not blank a
/// screen on a phone that has not been updated yet, and "I can't file this one" is
/// exactly what `.unfiled` already means. The same fallback covers an ABSENT `project`
/// key, which is what a bridge older than 0.72.0 sends.
///
/// The bridge sends the SLUG ONLY. The colour, the label and the ordering a client
/// draws from it are client concerns — see `TodayProjectPalette` in JesseTodayDisplay,
/// which is the one place any of those are decided.
public enum TodayProject: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case tag1
    case personal
    case network
    /// The one slug whose wire spelling is not its case name: the vault's topic page is
    /// `Dashboard/Via-Con-Me.md` and the bridge hyphenates it.
    case viaConMe = "via-con-me"
    case perseido
    /// No resolvable topic home. **Not an error and not a guess** — it is the honest
    /// answer for an item that declares no lineage, and on the live day file it is a
    /// large minority of items (45 of 94 when the bridge measured it). A client renders
    /// it as "no project", never as a sixth project.
    case unfiled

    /// The five real topics, in Dashboard order — `unfiled` excluded, because a filter
    /// bar or a legend that offered "unfiled" alongside them would present the absence
    /// of a project as one.
    public static let filed: [TodayProject] = [.tag1, .personal, .network, .viaConMe, .perseido]

    /// Whether this is the absence of a project rather than one.
    public var isUnfiled: Bool { self == .unfiled }

    /// Dashboard order, which is also the bridge's `PROJECT_SLUGS` order: the five
    /// topics as the vault lists them, then `unfiled` last. Used to order a
    /// project-grouped view so two devices group the day the same way.
    public var displayOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// An unknown slug is `.unfiled`, never a decode failure. See the type's note.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodayProject(rawValue: raw) ?? .unfiled
    }
}
