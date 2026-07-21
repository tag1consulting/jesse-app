import SwiftUI
import JesseNetworking

// The provenance chip view. The wire model (`JesseProvenance`/`JesseProvenanceFlags`), its
// persistence encoding, the badge/warning `strip(from:)`, and the pure presentation
// helpers (routeKind/label/iconName/accessibilityText) all live in JesseNetworking, shared
// with the macOS app. Only the SwiftUI rendering stays here.

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
