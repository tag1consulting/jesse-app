import SwiftUI
import JesseCore

// MARK: - Wire model

/// Structured, display-only provenance for a delivered reply — the machine-readable
/// sibling of the trailing text badge the bridge appends. Carried on BOTH the poll
/// result (`GET /jesse/result`) and the SSE `done` frame, next to `directives`. When
/// present, the app strips the text badge (and the emergency citations-unverified
/// warning) from the displayed message and renders this as a native chip instead;
/// when ABSENT (an older bridge, or badges off), the reply text is shown verbatim.
///
/// The exact strings the bridge emits are pinned by the shared fixture
/// `bridge/tests/fixtures/provenance.json`, which `ProvenanceFixtureTests` reads so
/// this side and the bridge can never drift.
nonisolated struct JesseProvenance: Decodable, Equatable {
    /// `hosted` | `vaultqa-local` | `diet-local` | `emergency-local` (same vocabulary
    /// as the bridge metrics route). Kept as the raw string so an unrecognized future
    /// route still decodes and renders a generic chip rather than failing.
    let route: String
    /// The backend model that produced the reply, or nil on a bare `[hosted]` turn.
    let model: String?
    /// The exact text badge appended to the reply — the string the app strips from the
    /// end of the displayed message.
    let badge: String
    let flags: JesseProvenanceFlags
}

nonisolated struct JesseProvenanceFlags: Decodable, Equatable {
    let hostedVerify: Bool
    let verifyQueued: Bool
    let citationsUnverified: Bool
    enum CodingKeys: String, CodingKey {
        case hostedVerify = "hosted_verify"
        case verifyQueued = "verify_queued"
        case citationsUnverified = "citations_unverified"
    }
}

// MARK: - Encoding for persistence

// The persisted `Turn` stores provenance as a compact JSON string. These make the
// exact same shape round-trip so a reply's chip survives relaunch and scrolling.
extension JesseProvenance: Encodable {}
extension JesseProvenanceFlags: Encodable {}

extension JesseProvenance {
    /// Encode to the compact JSON string persisted on `Turn.provenanceJSON`.
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Decode from a persisted `Turn.provenanceJSON`; nil for absent/malformed.
    static func from(json: String?) -> JesseProvenance? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JesseProvenance.self, from: data)
    }
}

// MARK: - The shared warning string

/// The exact line the bridge PREPENDS above the badge when an emergency answer was
/// delivered without a passing citation check (`flags.citationsUnverified`). Must equal
/// the bridge's `emergency::CITATIONS_UNVERIFIED_WARNING`; `ProvenanceFixtureTests`
/// asserts both this constant and the bridge's match the shared fixture.
let citationsUnverifiedWarning =
    "⚠️ citations unverified — the hosted assistant was unavailable, so this local answer " +
    "was delivered without a passing citation check. Double-check anything important."

// MARK: - Stripping the badge / warning from display text

extension JesseProvenance {
    /// Remove the bridge-appended badge — and, on an unverified emergency answer, the
    /// prepended warning line — from a reply's raw text, leaving just the answer body.
    /// Pure and exact-match: it strips ONLY the precise strings the bridge assembled
    /// (`…\n\n<badge>`, and `<warning>\n\n…`), never a badge-shaped string inside the
    /// model's own prose. When provenance is absent, callers skip this entirely and
    /// show the text verbatim (the older-bridge fallback).
    func strip(from text: String) -> String {
        var s = Substring(text)
        // Trailing badge: the bridge appends "\n\n" + badge at the very end.
        let suffix = "\n\n" + badge
        if s.hasSuffix(suffix) {
            s = s.dropLast(suffix.count)
        }
        // Leading warning: only on the unverified emergency path, prepended as
        // "<warning>\n\n" above the body.
        if flags.citationsUnverified {
            let prefix = citationsUnverifiedWarning + "\n\n"
            if s.hasPrefix(prefix) {
                s = s.dropFirst(prefix.count)
            }
        }
        return String(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Presentation (pure — no SwiftUI, so it is directly testable)

extension JesseProvenance {
    /// The tinting family for the chip: where the tokens went and how degraded the turn
    /// was. `citationsUnverified` forces the warning family regardless of route.
    enum Kind { case hosted, local, emergency, warning }

    var routeKind: Kind {
        if flags.citationsUnverified { return .warning }
        switch route {
        case "hosted": return .hosted
        case "vaultqa-local", "diet-local": return .local
        case "emergency-local": return .emergency
        default: return .local
        }
    }

    /// Whether the reply's citations were delivered unverified — the chip's warning state.
    var isWarning: Bool { flags.citationsUnverified }

    /// The short, human label shown in the chip.
    var label: String {
        if flags.verifyQueued { return "Queued for verify" }
        switch route {
        case "hosted": return "Hosted"
        case "vaultqa-local": return "Local · vault"
        case "diet-local": return "Local · diet"
        case "emergency-local": return "Emergency"
        default: return "Local"
        }
    }

    /// The SF Symbol that leads the chip.
    var iconName: String {
        if flags.citationsUnverified { return "exclamationmark.triangle.fill" }
        if flags.verifyQueued { return "clock.arrow.circlepath" }
        switch route {
        case "hosted": return "cloud"
        case "vaultqa-local": return "lock.doc"
        case "diet-local": return "fork.knife"
        case "emergency-local": return "exclamationmark.triangle"
        default: return "lock"
        }
    }

    /// The full accessibility sentence (route + model + any warning), for VoiceOver.
    var accessibilityText: String {
        var parts = [label]
        if let model, !model.isEmpty { parts.append("model \(model)") }
        if isWarning { parts.append("citations unverified") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The chip view

/// A subtle, iOS-normal capsule rendered under a Jesse message when provenance is
/// present. Distinct tint for local vs hosted vs emergency, and a warning state for
/// unverified citations. Purely derived from `JesseProvenance` (no side effects).
struct ProvenanceChip: View {
    let provenance: JesseProvenance

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: provenance.iconName)
                .font(.caption2)
            Text(provenance.label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provenance.accessibilityText)
    }

    private var tint: Color {
        switch provenance.routeKind {
        case .hosted: return .secondary
        case .local: return .teal
        case .emergency: return .orange
        case .warning: return .red
        }
    }
}
