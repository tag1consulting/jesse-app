import AVFoundation
import UIKit
import UniformTypeIdentifiers
import JesseSpeech

// The share sheet's half of "record a memo, tap Share, choose Jesse".
//
// IT DOES ONE THING: TAKE CUSTODY. It copies the incoming audio into the app group,
// records what the file was, opens the app, and finishes. It does NOT transcribe, and
// the reason is not tidiness — a share extension runs under a tight memory budget and is
// killed as soon as its sheet goes away, which is a few hundred milliseconds after the
// user taps. Transcribing an hour of audio here would be killed every single time, and
// killed silently.
//
// COPYING IS ALSO NOT TIDINESS. The URL `loadFileRepresentation` hands over is valid
// only inside its completion block and is scoped to this process; a reference passed to
// the app would be a path the app cannot open. The bytes have to move.
//
// WHAT MAKES IT SURVIVE BEING KILLED. Nothing here depends on the app opening. The
// hand-off is a file plus a manifest in a shared container, and the app drains that
// directory at launch and at every foreground. `open` below is a convenience that saves
// the user a tap; if it silently fails — and on iOS an extension's `open` sometimes does
// — the recording is still waiting the next time Jesse is looked at.
final class ShareAudioViewController: UIViewController {

    /// Bringing the app forward. It carries no payload: the hand-off is the file in the
    /// app group, and a URL that also named it would be a second source of truth able to
    /// disagree with the directory.
    private static let hostURL = URL(string: "jesse://share-audio")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addStatusLabel()
        Task { await takeCustody() }
    }

    /// A single line, because the sheet is on screen for well under a second and the
    /// only thing worth saying is which app just took the recording.
    private func addStatusLabel() {
        let label = UILabel()
        label.text = "Sending to Jesse…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let backing = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.layer.cornerRadius = 14
        backing.clipsToBounds = true
        view.addSubview(backing)
        backing.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            backing.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            backing.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: backing.contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: backing.contentView.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: backing.contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: backing.contentView.bottomAnchor, constant: -18),
        ])
    }

    private func takeCustody() async {
        defer { finish() }

        guard let store = RecordingHandoffStore.shared() else { return }
        guard let provider = audioProvider() else { return }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .audio) == true
        }) else { return }

        guard let staged = await stage(provider, as: identifier, into: store) else { return }
        _ = staged
        openHostApp()
    }

    /// The first attachment that is actually audio. The activation rule in `Info.plist`
    /// already narrows the sheet to one audio item, so this is a belt-and-braces read
    /// rather than a filter doing real work.
    private func audioProvider() -> NSItemProvider? {
        for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            for provider in item.attachments ?? [] where provider.registeredTypeIdentifiers
                .contains(where: { UTType($0)?.conforms(to: .audio) == true }) {
                return provider
            }
        }
        return nil
    }

    /// Copy the audio into the app group and write its manifest.
    ///
    /// Everything that touches the loaned URL happens INSIDE the completion block, which
    /// is the only place it is valid: the copy, the name, and the duration probe.
    private func stage(_ provider: NSItemProvider,
                       as identifier: String,
                       into store: RecordingHandoffStore) async -> PendingRecording? {
        // Read off the provider HERE: `NSItemProvider` is not `Sendable`, so it cannot be
        // captured by the `@Sendable` completion block below.
        let suggested = provider.suggestedName ?? "Recording"
        return await withCheckedContinuation { (continuation: CheckedContinuation<PendingRecording?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                // The loaned file's own name is the one the user knows it by (Voice Memos
                // names its recordings); the provider's suggestion is the fallback for one
                // that vends an anonymous temporary.
                let name = url.lastPathComponent.isEmpty ? suggested : url.lastPathComponent
                // Probed HERE, where the file is definitely readable, so the app has the
                // length before it has decided to open the recording.
                let seconds = try? AVAudioFileProbe().facts(forFileAt: url).durationSeconds
                let staged = try? store.stage(copying: url,
                                              originalName: name,
                                              durationSeconds: seconds)
                continuation.resume(returning: staged)
            }
        }
    }

    private func openHostApp() {
        guard let url = Self.hostURL else { return }
        extensionContext?.open(url)
    }

    /// Always completes, and always successfully. A hand-off that failed has left
    /// nothing behind (`stage` removes a half-written pair itself), and an error sheet
    /// over the share UI would be a dead end — the app is where anything can be said
    /// about it.
    private func finish() {
        extensionContext?.completeRequest(returningItems: [])
    }
}
