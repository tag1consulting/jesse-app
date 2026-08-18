import SwiftUI
import SwiftData
import UIKit
import QuickLook
import JesseCore
import JesseNetworking

// How a file Jesse returned renders under its reply.
//
// Two shapes, decided by the mime the BRIDGE sniffed from the bytes (never by the
// filename — the model chose that, and the bridge deliberately never let it reach a path):
//
//   * a PNG or JPEG renders INLINE at a bounded size, tappable to full screen;
//   * everything else renders as a CHIP — filename, type icon, size — opening in
//     QuickLook, with a share sheet alongside.
//
// SVG is deliberately in the second group even though it is an image. It is markup and a
// rendering surface, so it goes behind the same explicit tap a PDF is behind rather than
// being drawn automatically into a transcript.
//
// Every download is LAZY — on first display, never on delivery — because a thread may
// hold dozens of files the user never opens, and each is a real network round trip.

/// The row of a turn's returned files.
struct TurnArtifactsView: View {
    let artifacts: [TurnArtifact]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(artifacts) { artifact in
                ArtifactItemView(artifact: artifact)
            }
        }
    }
}

/// One returned file, with its own load state.
///
/// State lives per item rather than in a shared store because each is independently
/// fetched, independently cached and independently able to fail — and because a view that
/// held them centrally would have to invalidate on every thread change, which is exactly
/// the bookkeeping SwiftUI's per-view `@State` already does correctly.
private struct ArtifactItemView: View {
    @Bindable var artifact: TurnArtifact
    @Environment(\.modelContext) private var context
    @Environment(RunCoordinator.self) private var coordinator

    @State private var state: ArtifactLoadState = .idle
    @State private var previewURL: URL?
    @State private var showFullScreen = false

    /// Inline images are capped so a tall chart cannot push the rest of the conversation
    /// off screen. The full-resolution file is one tap away.
    private static let maxInlineHeight: CGFloat = 240

    var body: some View {
        content
            .task {
                // `.task` runs on first appearance and is cancelled when the view goes
                // away, which is exactly the lazy-on-first-display rule. The `idle` guard
                // keeps a scroll that re-appears the row from re-downloading.
                guard case .idle = state else { return }
                await load()
            }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .loading:
            placeholder(icon: artifact.typeIcon, trailing: ProgressView().controlSize(.mini))
        case .expired:
            // PERMANENT. No retry button, because there is nothing to retry: the bridge's
            // TTL, its high-water mark, or a conversation delete removed the file. Saying
            // "no longer available" is the honest end state.
            placeholder(icon: "clock.badge.xmark",
                        subtitle: "No longer available on the bridge")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                placeholder(icon: "exclamationmark.triangle", subtitle: message)
                Button("Try again") {
                    state = .idle
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .ready(let url):
            if artifact.isInlineImage, let image = UIImage(contentsOfFile: url.path) {
                inlineImage(image, url: url)
            } else {
                chip(url: url)
            }
        }
    }

    // MARK: - The two shapes

    private func inlineImage(_ image: UIImage, url: URL) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Self.maxInlineHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(artifact.filename)
            .onTapGesture { showFullScreen = true }
            .fullScreenCover(isPresented: $showFullScreen) {
                ArtifactFullScreenView(image: image, filename: artifact.filename, url: url)
            }
    }

    private func chip(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: artifact.typeIcon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(artifact.displaySize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { previewURL = url }
        .quickLookPreview($previewURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artifact.filename), \(artifact.displaySize)")
        .accessibilityAddTraits(.isButton)
    }

    /// The pending / expired / failed shape: the same chip geometry, so a file that is
    /// still downloading does not change size the instant it lands.
    private func placeholder(icon: String,
                             subtitle: String? = nil,
                             trailing: (some View)? = Optional<EmptyView>.none) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle ?? artifact.displaySize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Loading

    private func load() async {
        state = .loading
        let loader = ArtifactLoader { coordinator.artifactClient() }
        let result = await loader.load(artifact)
        state = result
        // The loader may have written the PERMANENT expired verdict onto the row. Persist
        // it, or the next launch re-fetches a dead id — which is the retry loop the whole
        // sticky-verdict design exists to prevent.
        if case .expired = result {
            try? context.save()
        }
    }
}

/// A returned image at full screen, with the share sheet and a dismiss.
private struct ArtifactFullScreenView: View {
    let image: UIImage
    let filename: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}
