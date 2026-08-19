import SwiftUI
import SwiftData
import AppKit
import QuickLookUI
import JesseCore
import JesseNetworking

// The Mac's rendering of a file Jesse returned — the same two shapes iOS uses, decided by
// the same rule (the mime the BRIDGE sniffed from the bytes, never the filename):
//
//   * a PNG, JPEG or SVG renders INLINE at a bounded size, clicking opens the previewer;
//   * everything else renders as a CHIP — filename, type icon, size — with QuickLook,
//     Reveal in Finder and Save As.
//
// SVG used to be in the second group, on the reasoning that it is markup and a rendering
// surface. It is in the first group now: `NSImage` draws SVG through its own vector
// representation, which is a parser and not a browser — no scripting, no network, no DOM
// — and it returns nil on markup it cannot parse, which is what gives the chip fallback
// below its exact condition. `ArtifactFileType.isInlineImage` carries the full reasoning.
//
// # Why QuickLook is given an item rather than a URL
//
// SwiftUI's `.quickLookPreview` takes a bare `URL?`, and a bare URL was not enough to
// preview with: QuickLook types a file from its extension, the cache wrote none, and every
// non-image opened blank. `ArtifactFileType` fixes the naming; `ArtifactPreviewItem` adds
// the other half a URL cannot carry — the file's DISPLAY name, since the URL's own last
// component is a hex id and the previewer would otherwise title the window `4f2a91c0…`.
// That means driving `QLPreviewView` directly instead of the modifier.
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
    @State private var previewing: ArtifactPreviewItem?

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
            .sheet(item: $previewing) { item in
                MacArtifactPreviewSheet(item: item)
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
            // `NSImage` is the parse check as well as the renderer: nil means these bytes
            // are not a picture this system can draw — a truncated PNG, malformed SVG —
            // and the chip is the honest fallback. Never an empty box.
            if artifact.isInlineImage, let image = NSImage(contentsOf: url) {
                inlineImage(image, url: url)
            } else {
                fileChip(url: url)
            }
        }
    }

    private func inlineImage(_ image: NSImage, url: URL) -> some View {
        let frame = ArtifactFileType.inlineFrame(intrinsic: image.size,
                                                 maxWidth: Self.maxInlineWidth,
                                                 maxHeight: Self.maxInlineHeight)
        return Image(nsImage: image)
            .resizable()
            // `.fill` only for the extreme proportions that would otherwise fit down to a
            // few points wide — see `ArtifactFileType.inlineFrame`.
            .aspectRatio(contentMode: frame.crops ? .fill : .fit)
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(artifact.filename)
            .onTapGesture { preview(url) }
            .contextMenu { fileActions(url) }
    }

    private func fileChip(url: URL) -> some View {
        chipShell(icon: artifact.typeIcon, subtitle: artifact.displaySize) { EmptyView() }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { preview(url) }
            .contextMenu { fileActions(url) }
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func fileActions(_ url: URL) -> some View {
        Button("Quick Look") { preview(url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Save As…") { saveAs(url) }
    }

    private func preview(_ url: URL) {
        previewing = ArtifactPreviewItem(url: url, filename: artifact.filename,
                                         mime: artifact.mime)
    }

    /// Copy the cached bytes somewhere the user chose.
    ///
    /// The model's filename is the SUGGESTED name and only that — the destination is
    /// whatever the panel returns after the user has seen and confirmed it, so this is the
    /// one place the model's string is allowed near a path. The `UTType` is the other half
    /// of naming it correctly, and the one caller that genuinely takes one.
    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        if let type = ArtifactFileType.contentType(for: artifact.mime) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // The panel already asked about replacing, so an existing file here is one the
        // user chose to overwrite; `copyItem` will not do it on its own.
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
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

// ---- QuickLook, driven directly --------------------------------------------

/// The sheet a preview opens in, with the file's own name on it.
private struct MacArtifactPreviewSheet: View {
    let item: ArtifactPreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MacQuickLookView(item: item)
                .frame(minWidth: 480, minHeight: 360)
            Divider()
            HStack {
                Text(item.previewItemTitle ?? "")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 720, height: 560)
    }
}

/// `QLPreviewView` as a SwiftUI view.
///
/// The AppKit half of the same choice the header describes: this is what accepts a
/// `QLPreviewItem`, where `.quickLookPreview` accepts only a URL and so could carry
/// neither the type nor the title.
private struct MacQuickLookView: NSViewRepresentable {
    let item: ArtifactPreviewItem

    func makeNSView(context: Context) -> TrackedPreviewView {
        let view = TrackedPreviewView()
        view.autostarts = true
        view.previewItem = item
        return view
    }

    func updateNSView(_ view: TrackedPreviewView, context: Context) {
        if (view.previewItem as AnyObject?) !== item {
            view.previewItem = item
        }
    }

    /// `QLPreviewView` holds a preview session that outlives the view unless it is closed
    /// explicitly. Without this, opening several files in a row leaks one per preview.
    static func dismantleNSView(_ view: TrackedPreviewView, coordinator: ()) {
        view.closeIfStarted()
    }

    /// A `QLPreviewView` that knows whether it ever started a session.
    ///
    /// `close()` is NOT safe to call unconditionally: on a view that never reached a
    /// window, QuickLook's own `deactivate` raises an assert and **aborts the process**
    /// (observed directly — `_QLRaiseAssert` inside `-[QLPreviewView deactivate]`, signal
    /// 6). A sheet torn down before its window materializes would otherwise take the app
    /// with it. `autostarts` means the session begins when the view gets a window, so
    /// "did it ever have a window" is exactly the right question to gate the close on.
    final class TrackedPreviewView: QLPreviewView {
        private var started = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { started = true }
        }

        func closeIfStarted() {
            guard started else { return }
            started = false
            close()
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
                id: artifact.artifactID, mime: artifact.mime, byteCount: artifact.byteCount,
                filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
                fetch: { _ in throw ArtifactFetchError.notConfigured })
        }
        let state = await ArtifactResolver.resolve(
            id: artifact.artifactID, mime: artifact.mime, byteCount: artifact.byteCount,
            filename: artifact.filename, isExpired: artifact.isExpired, cache: cache,
            fetch: { try await client.artifact(id: $0) })
        if case .expired = state { artifact.isExpired = true }
        return state
    }
}
