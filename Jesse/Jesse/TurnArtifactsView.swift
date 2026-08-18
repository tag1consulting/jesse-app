import SwiftUI
import SwiftData
import UIKit
import Photos
import QuickLook
import WebKit
import JesseCore
import JesseNetworking

// How a file Jesse returned renders under its reply.
//
// Two shapes, decided by the mime the BRIDGE sniffed from the bytes (never by the
// filename — the model chose that, and the bridge deliberately never let it reach a path):
//
//   * a PNG, JPEG or SVG renders INLINE at a bounded size, tappable to a full-screen
//     viewer with zoom, share and Save to Photos;
//   * everything else renders as a CHIP — filename, type icon, size — opening in
//     QuickLook, with a share sheet alongside.
//
// SVG used to be in the second group, on the reasoning that it is markup and a rendering
// surface and so belonged behind the same explicit tap a PDF is behind. It is in the first
// group now. The reasoning was answering a real concern with the wrong instrument: what
// makes SVG safe to draw is the sandbox around the renderer, not the number of taps in
// front of it. See `SandboxedSVGView` below for what that sandbox actually is, and
// `ArtifactFileType.isInlineImage` for the rule both platforms now share.
//
// # Why QuickLook is given an item rather than a URL
//
// SwiftUI's `.quickLookPreview` takes a bare `URL?`, and a bare URL was not enough to
// preview with: QuickLook types a file from its extension, the cache wrote none, and every
// non-image opened blank. `ArtifactFileType` fixes the naming; `ArtifactPreviewItem` adds
// what a URL cannot carry — the file's DISPLAY name, since the URL's own last component is
// a hex id and the previewer would otherwise title it `4f2a91c0…`. That means driving
// `QLPreviewController` directly instead of the modifier.
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
    @State private var previewing: ArtifactPreviewItem?
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
            .sheet(item: $previewing) { item in
                QuickLookSheet(item: item)
                    .ignoresSafeArea()
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
            readyContent(url)
        }
    }

    /// The inline-or-chip decision, and the two ways inline can decline.
    ///
    /// Both renderers are their own parse check, which is what keeps a broken file out of
    /// the transcript as an empty box: `UIImage` returns nil on raster bytes it cannot
    /// decode, and `ArtifactFileType.svgIntrinsicSize` returns nil on markup that is not
    /// well-formed XML rooted at `<svg>`. Either nil falls through to the chip, where the
    /// file is still openable and still shareable.
    @ViewBuilder private func readyContent(_ url: URL) -> some View {
        if artifact.mime == "image/svg+xml",
           let data = try? Data(contentsOf: url),
           let size = ArtifactFileType.svgIntrinsicSize(data) {
            inlineSVG(data, intrinsic: size, url: url)
        } else if artifact.isInlineImage, artifact.mime != "image/svg+xml",
                  let image = UIImage(contentsOfFile: url.path) {
            inlineImage(image, url: url)
        } else {
            chip(url: url)
        }
    }

    // MARK: - The two shapes

    private func inlineImage(_ image: UIImage, url: URL) -> some View {
        // The available width is not known until layout, and the frame math needs it, so
        // the picture sizes itself inside a container bounded only in height.
        InlineImageContainer(maxHeight: Self.maxInlineHeight,
                             intrinsic: image.size) { computed in
            Image(uiImage: image)
                .resizable()
                // `.fill` only for the extreme proportions that would otherwise fit down
                // to a few points wide — see `ArtifactFileType.inlineFrame`.
                .aspectRatio(contentMode: computed.crops ? .fill : .fit)
                .frame(width: computed.width, height: computed.height)
        }
        .modifier(InlineImageChrome(label: artifact.filename))
        .onTapGesture { showFullScreen = true }
        .fullScreenCover(isPresented: $showFullScreen) {
            ArtifactFullScreenView(content: .raster(image), artifact: artifact, url: url)
        }
    }

    private func inlineSVG(_ data: Data, intrinsic: CGSize, url: URL) -> some View {
        InlineImageContainer(maxHeight: Self.maxInlineHeight,
                             intrinsic: intrinsic) { computed in
            SandboxedSVGView(data: data, allowsZoom: false)
                .frame(width: computed.width, height: computed.height)
        }
        .modifier(InlineImageChrome(label: artifact.filename))
        .onTapGesture { showFullScreen = true }
        .fullScreenCover(isPresented: $showFullScreen) {
            ArtifactFullScreenView(content: .svg(data), artifact: artifact, url: url)
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
        .onTapGesture {
            previewing = ArtifactPreviewItem(url: url, filename: artifact.filename,
                                             mime: artifact.mime)
        }
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

// ---- Inline picture chrome -------------------------------------------------

/// Sizes an inline picture against the width it actually got.
///
/// `ArtifactFileType.inlineFrame` needs both bounds to decide whether a picture can be
/// letterboxed or has to be cropped, and the width bound is whatever the bubble gives us.
/// A `GeometryReader` is normally the wrong tool for sizing content, because it takes all
/// the space offered; here it is reading a width inside a container already bounded to
/// `maxHeight`, and the child it builds is fully sized, so nothing is left to expand.
private struct InlineImageContainer<Content: View>: View {
    let maxHeight: CGFloat
    let intrinsic: CGSize
    @ViewBuilder let content: (InlineImageFrame) -> Content

    var body: some View {
        GeometryReader { proxy in
            let computed = ArtifactFileType.inlineFrame(intrinsic: intrinsic,
                                                        maxWidth: proxy.size.width,
                                                        maxHeight: maxHeight)
            content(computed)
                .frame(width: proxy.size.width, height: maxHeight, alignment: .leading)
        }
        .frame(height: maxHeight)
    }
}

/// Rounded corners, a hairline border, and the model's filename as the label — the same
/// chrome for a raster picture and a vector one.
private struct InlineImageChrome: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }
}

// ---- Drawing an SVG without becoming a browser -----------------------------

/// An SVG, rendered by WebKit with everything WebKit is dangerous for switched off.
///
/// # Why a web view at all
///
/// `UIImage` cannot draw SVG — not from `Data`, not from a file, with or without the
/// extension (verified against this SDK, not assumed). The private CoreSVG entry point
/// `CGSVGDocumentCreateFromData` is what `NSImage` uses on the Mac and is not callable
/// from public API, so on iOS a web view is the only vector renderer the platform offers.
///
/// # The sandbox
///
/// Four independent limits, because "the renderer is a browser engine" deserves more than
/// one:
///
///   1. `allowsContentJavaScript = false` — no script runs, at the WebKit level, whatever
///      the markup contains.
///   2. A `default-src 'none'` Content-Security-Policy on the wrapper document — nothing
///      may be fetched: no image, no font, no stylesheet, no beacon.
///   3. A navigation delegate that permits the initial load and CANCELS every navigation
///      after it, so a document that tries to leave cannot.
///   4. An opaque origin (`about:blank`) as the base URL. The brief asked for a fixed
///      local base; a `file://` base would be fixed and local and STRICTLY WORSE, because
///      it grants the document read access to the directory it names. The markup is
///      inlined into the wrapper, so it needs no base at all, and an opaque origin is the
///      base that grants nothing.
///
/// The bytes reaching here have also already been proven by the bridge to be UTF-8 text
/// with no control characters and no `#!`, and re-parsed on this device as well-formed XML
/// rooted at `<svg>` with external entities unresolved.
private struct SandboxedSVGView: UIViewRepresentable {
    let data: Data
    /// Full screen lets the user pinch the drawing itself; inline does not, so the gesture
    /// belongs to the transcript's scroll view rather than being stolen by a subview.
    let allowsZoom: Bool

    func makeCoordinator() -> NavigationBlocker { NavigationBlocker() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // A non-persistent store: nothing this document does can touch cookies or storage
        // that outlive it.
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = allowsZoom
        view.scrollView.bouncesZoom = allowsZoom
        view.isUserInteractionEnabled = allowsZoom
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.loadHTMLString(Self.document(for: data, allowsZoom: allowsZoom),
                            baseURL: URL(string: "about:blank"))
    }

    /// The wrapper the markup is inlined into, carrying the policy and the sizing.
    private static func document(for data: Data, allowsZoom: Bool) -> String {
        // Non-UTF-8 cannot reach here: the bridge only labels bytes `image/svg+xml` after
        // decoding them as UTF-8, and `svgIntrinsicSize` has re-parsed them since.
        let markup = String(decoding: data, as: UTF8.self)
        let scale = allowsZoom
            ? "width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=8"
            : "width=device-width, initial-scale=1, user-scalable=no"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="\(scale)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        html,body{margin:0;padding:0;height:100%;background:transparent;overflow:hidden}
        body{display:flex;align-items:center;justify-content:center}
        svg{max-width:100%;max-height:100%;height:auto;width:auto}
        </style></head><body>\(markup)</body></html>
        """
    }

    /// Permits the load that this view itself started and refuses every other navigation.
    /// The document has no network reachable by policy already; this is the second lock on
    /// the same door, and the one that also covers a link the user could tap.
    @MainActor
    final class NavigationBlocker: NSObject, WKNavigationDelegate {
        /// The bytes currently loaded, so a re-render of the same drawing does not reload
        /// the web view on every SwiftUI update.
        var loaded: Data?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction)
            async -> WKNavigationActionPolicy {
            // The load this view itself started is `.other` at the opaque origin. A link
            // tap, a redirect, a form post, a subframe fetching anything: all cancelled.
            navigationAction.navigationType == .other
                && navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}

// ---- QuickLook -------------------------------------------------------------

/// `QLPreviewController` as a SwiftUI sheet, given the item rather than a bare URL.
private struct QuickLookSheet: UIViewControllerRepresentable {
    let item: ArtifactPreviewItem

    func makeCoordinator() -> Source { Source(item: item) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = item
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var item: ArtifactPreviewItem
        init(item: ArtifactPreviewItem) { self.item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { item }
    }
}

// ---- Full screen -----------------------------------------------------------

/// A returned picture at full screen: zoom, pan, share, and Save to Photos.
private struct ArtifactFullScreenView: View {
    /// Which renderer the picture needs. The two cases are not interchangeable — a raster
    /// image can go to Photos and an SVG cannot, and only one of them zooms in a scroll
    /// view rather than in the web view's own.
    enum Content {
        case raster(UIImage)
        case svg(Data)
    }

    let content: Content
    let artifact: TurnArtifact
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var saveOutcome: PhotoSaveOutcome?

    var body: some View {
        NavigationStack {
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.92))
                .navigationTitle(artifact.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                    if case .raster(let image) = content {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Task { saveOutcome = await PhotoSaver.save(image: image, at: url) }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .accessibilityLabel("Save to Photos")
                        }
                    }
                }
                .alert(saveOutcome?.title ?? "", isPresented: saveAlertBinding) {
                    Button("OK", role: .cancel) { saveOutcome = nil }
                } message: {
                    Text(saveOutcome?.message ?? "")
                }
        }
    }

    @ViewBuilder private var picture: some View {
        switch content {
        case .raster(let image):
            ZoomableImageView(image: image)
        case .svg(let data):
            // WebKit's own pinch-zoom, which is the vector one: zooming re-rasterizes at
            // the new scale instead of magnifying pixels.
            SandboxedSVGView(data: data, allowsZoom: true)
        }
    }

    private var saveAlertBinding: Binding<Bool> {
        Binding(get: { saveOutcome != nil }, set: { if !$0 { saveOutcome = nil } })
    }
}

/// What came of a Save to Photos, as something to show the user.
private struct PhotoSaveOutcome {
    let title: String
    let message: String
}

/// Save to Photos, through the add-only authorization.
///
/// `.addOnly` is the narrow half of the Photos permission and all this needs: it can add
/// an asset and cannot enumerate the library. The Info.plist string that goes with it is
/// `NSPhotoLibraryAddUsageDescription`.
private enum PhotoSaver {
    @MainActor
    static func save(image: UIImage, at url: URL) async -> PhotoSaveOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return PhotoSaveOutcome(
                title: "Photos access is off",
                message: "Allow adding photos for Jesse in Settings to save this picture.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // From the FILE, not from the decoded `UIImage`: the cached bytes are the
                // original, and re-encoding a `UIImage` would hand Photos a lossy copy of
                // a PNG the model rendered exactly once.
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }
            return PhotoSaveOutcome(title: "Saved", message: "Added to your photo library.")
        } catch {
            // The likeliest cause by far is a file Photos will not accept as a photo.
            _ = image
            return PhotoSaveOutcome(title: "Couldn't save",
                               message: error.localizedDescription)
        }
    }
}

/// A picture in a `UIScrollView`, which is where pinch, pan and double-tap zoom already
/// work correctly.
///
/// SwiftUI's `MagnifyGesture` can be assembled into something similar, but not into
/// something that composes zoom with pan and with the rubber-banding at the limits that
/// makes zooming feel like the rest of the system. This is the control that does.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 8
        scrollView.minimumZoomScale = 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.imageView.image = image
        context.coordinator.imageView = scrollView.imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingScrollView, context: Context) {
        scrollView.imageView.image = image
    }

    /// The image view is laid out HERE and not in `updateUIView`.
    ///
    /// That is the whole reason this subclass exists. `updateUIView` runs before SwiftUI
    /// has given the scroll view a size, so sizing the image against `bounds` there set a
    /// zero frame — and SwiftUI does not call it again when the real size arrives, so the
    /// viewer opened to its chrome and an empty black rectangle. `layoutSubviews` runs
    /// every time the size actually changes, which is when this question can be answered.
    final class ZoomingScrollView: UIScrollView {
        let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.isUserInteractionEnabled = true
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Only while zoomed OUT. Above the minimum the scroll view owns the zooming
            // view's transform and its content size, and writing a frame would fight it.
            guard zoomScale == minimumZoomScale else { return }
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom to where the finger landed rather than to the middle, so a
                // double-tap on a detail brings up that detail.
                let point = gesture.location(in: imageView)
                let scale = min(scrollView.maximumZoomScale, 3)
                let size = CGSize(width: scrollView.bounds.width / scale,
                                  height: scrollView.bounds.height / scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2,
                                           y: point.y - size.height / 2,
                                           width: size.width, height: size.height),
                                animated: true)
            }
        }
    }
}
