import SwiftUI
import SwiftData
import AppKit
import QuickLook
import JesseCore
import JesseNetworking

// The Mac's rendering of a file Jesse returned — the same two shapes iOS uses, decided by
// the same rule (the mime the BRIDGE sniffed from the bytes, never the filename):
//
//   * a PNG or JPEG renders INLINE at a bounded size, clicking opens the system previewer;
//   * everything else renders as a CHIP — filename, type icon, size — with QuickLook and
//     Reveal in Finder.
//
// SVG is deliberately in the second group even though it is an image: it is markup and a
// rendering surface, so it goes behind an explicit click rather than being drawn into a
// transcript automatically.
//
// The download is LAZY, on first display. The load state, the cache, and the PERMANENT
// expired verdict all live in `MacArtifactLoader` below, which is the Mac's peer of the
// iOS `ArtifactLoader` and holds the same rules.

/// The row of a turn's returned files.
struct MacTurnArtifactsView: View {
    let artifacts: [TurnArtifact]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(artifacts) { artifact in
                MacArtifactItemView(artifact: artifact)
            }
        }
    }
}

private struct MacArtifactItemView: View {
    @Bindable var artifact: TurnArtifact
    @Environment(\.modelContext) private var context
    @Environment(MacCoordinator.self) private var coordinator

    @State private var state: ArtifactLoadState = .idle
    @State private var previewURL: URL?

    /// Bounded so a tall chart cannot push the rest of the conversation off screen.
    private static let maxInlineHeight: CGFloat = 280
    private static let maxInlineWidth: CGFloat = 460

    var body: some View {
        content
            .task {
                // First appearance only: the `idle` guard keeps a scroll that re-appears
                // the row from re-downloading.
                guard case .idle = state else { return }
                await load()
            }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .loading:
            chipShell(icon: artifact.typeIcon, subtitle: artifact.displaySize) {
                ProgressView().controlSize(.small)
            }
        case .expired:
            // PERMANENT — no retry, because there is nothing to retry. The bridge's TTL,
            // its high-water mark, or a conversation delete removed the file.
            chipShell(icon: "clock.badge.xmark", subtitle: "No longer available on the bridge") {
                EmptyView()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                chipShell(icon: "exclamationmark.triangle", subtitle: message) { EmptyView() }
                Button("Try again") {
                    state = .idle
                    Task { await load() }
                }
                .controlSize(.small)
            }
        case .ready(let url):
            if artifact.isInlineImage, let image = NSImage(contentsOf: url) {
                inlineImage(image, url: url)
            } else {
                fileChip(url: url)
            }
        }
    }

    private func inlineImage(_ image: NSImage, url: URL) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: Self.maxInlineWidth, maxHeight: Self.maxInlineHeight,
                   alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(artifact.filename)
            .onTapGesture { previewURL = url }
            .quickLookPreview($previewURL)
            .contextMenu { fileActions(url) }
    }

    private func fileChip(url: URL) -> some View {
        chipShell(icon: artifact.typeIcon, subtitle: artifact.displaySize) { EmptyView() }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { previewURL = url }
            .quickLookPreview($previewURL)
            .contextMenu { fileActions(url) }
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func fileActions(_ url: URL) -> some View {
        Button("Quick Look") { previewURL = url }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The one chip geometry every state shares, so a file that is still downloading does
    /// not change size the instant it lands.
    private func chipShell(icon: String, subtitle: String,
                           @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artifact.filename), \(subtitle)")
    }

    private func load() async {
        state = .loading
        let loader = MacArtifactLoader { coordinator.artifactClient() }
        let result = await loader.load(artifact)
        state = result
        // The loader may have written the PERMANENT expired verdict onto the row. Persist
        // it, or the next launch re-fetches a dead id.
        if case .expired = result {
            try? context.save()
        }
    }
}

/// The Mac's binding of one `TurnArtifact` to bytes on disk.
///
/// Every rule — cache first, the PERMANENT expired verdict, the wording of each failure —
/// lives in `ArtifactResolver` (JesseNetworking), shared with iOS. This type is the two
/// things that genuinely differ per app: WHICH client protocol does the fetch, and
/// recording the verdict on the SwiftData row.
@MainActor
struct MacArtifactLoader {
    let cache: ArtifactCache?
    let makeClient: @MainActor () -> (any BridgeClientProtocol)?

    init(cache: ArtifactCache? = ArtifactCache.standard(),
         makeClient: @escaping @MainActor () -> (any BridgeClientProtocol)?) {
        self.cache = cache
        self.makeClient = makeClient
    }

    func load(_ artifact: TurnArtifact) async -> ArtifactLoadState {
        guard let client = makeClient() else {
            // Not paired. Still go through the resolver, so a file this Mac already
            // downloaded shows from the cache rather than behind a settings error.
            return await ArtifactResolver.resolve(
                id: artifact.artifactID, byteCount: artifact.byteCount,
                filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
                fetch: { _ in throw ArtifactFetchError.notConfigured })
        }
        let state = await ArtifactResolver.resolve(
            id: artifact.artifactID, byteCount: artifact.byteCount,
            filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
            fetch: { try await client.artifact(id: $0) })
        if case .expired = state { artifact.isExpired = true }
        return state
    }
}
