import AppIntents
import Combine
import Foundation
import SwiftData
import JesseCore

// Bridge between Siri and the app. Siri captures the spoken text into `text`,
// we stash it, open the app, and ContentView runs it (no timeout) + speaks the
// reply. App Shortcuts auto-register on first launch — no Siri entitlement.

struct PendingVoiceRequest: Equatable {
    let id = UUID()
    let mode: JesseMode
    let text: String
}

// The hands-free "doorbell": Siri's only job is to foreground the app into
// listening mode. There is NO spoken text yet — unlike `PendingVoiceRequest`,
// this carries no `text`. The app captures the actual request in-app with
// `SFSpeechRecognizer` (see `VoiceCapture`) and only then runs a turn. This is
// what sidesteps Siri's unreliable free-text `requestValueDialog` capture.
struct PendingWakeRequest: Equatable {
    let id = UUID()
    /// The mode the captured request runs as (a bare wake is an Ask).
    let mode: JesseMode
}

// Cross-launch hand-off: UserDefaults survives a cold launch; the @Published
// property makes a warm hand-off instant. ContentView drains it on becoming active.
//
// `@MainActor` so `pending` is only ever mutated on the main actor — the
// cold-launch `enqueue` path previously hopped to `DispatchQueue.main` by hand,
// which left the mutation unprotected under strict concurrency. The annotation
// makes that invariant compiler-enforced.
@MainActor
final class JesseInbox: ObservableObject {
    static let shared = JesseInbox()
    /// A request whose text is already known (the typed / Shortcuts-app path and
    /// the watch relay). ContentView runs it directly.
    @Published var pending: PendingVoiceRequest?
    /// A hands-free wake: foreground and start listening in-app. No text yet —
    /// ContentView starts `SFSpeechRecognizer` capture and only then runs a turn.
    @Published var pendingWake: PendingWakeRequest?

    private let dMode = "jesse.pending.mode"
    private let dText = "jesse.pending.text"
    private let dWakeMode = "jesse.pending.wakeMode"

    func enqueue(mode: JesseMode, text: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: dMode)
        UserDefaults.standard.set(text, forKey: dText)
        // Already on the main actor; defer the drain to the next runloop tick so the
        // intent's `perform()` returns first (preserving the prior async behavior).
        Task { @MainActor in self.drain() }
    }

    /// Enqueue a hands-free wake (start listening in-app). Persists only a mode —
    /// no text — so a cold launch reconstitutes "start listening", not a stale
    /// spoken value.
    func enqueueWake(mode: JesseMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: dWakeMode)
        Task { @MainActor in self.drain() }
    }

    /// Pick up whatever is queued — a text request and/or a wake signal (call on
    /// launch/foreground). The two are independent; each is cleared as it's drained
    /// so it fires exactly once.
    func drain() {
        if let m = UserDefaults.standard.string(forKey: dMode),
           let mode = JesseMode(rawValue: m),
           let text = UserDefaults.standard.string(forKey: dText),
           !text.isEmpty {
            UserDefaults.standard.removeObject(forKey: dMode)
            UserDefaults.standard.removeObject(forKey: dText)
            pending = PendingVoiceRequest(mode: mode, text: text)
        }

        if let m = UserDefaults.standard.string(forKey: dWakeMode),
           let mode = JesseMode(rawValue: m) {
            UserDefaults.standard.removeObject(forKey: dWakeMode)
            pendingWake = PendingWakeRequest(mode: mode)
        }
    }
}

struct AskJesseIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jesse"
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What's your question?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        JesseInbox.shared.enqueue(mode: .ask, text: text)
        return .result()
    }
}

struct TellJesseIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Jesse"
    static let openAppWhenRun = true

    @Parameter(title: "Message", requestValueDialog: "What should I note?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        JesseInbox.shared.enqueue(mode: .tell, text: text)
        return .result()
    }
}

/// The hands-free doorbell. Its ONLY job is to foreground the app into listening
/// mode — no `@Parameter`, no `requestValueDialog`, so Siri never tries to parse
/// the open-ended request. The app captures the request itself once it's open.
struct WakeJesseIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Jesse"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // A bare wake is an Ask; the captured text runs through the same turn path.
        JesseInbox.shared.enqueueWake(mode: .ask)
        return .result()
    }
}

/// **Capture something without opening the app.**
///
/// The three intents above all set `openAppWhenRun = true`, and that is deliberate for
/// what they do: an Ask needs somewhere to show the answer, and a hands-free wake needs
/// the app in front of you to listen. But the commonest thing anyone actually says to
/// this assistant is a note — "log the run", "remember the vendor called" — and for that,
/// bringing the whole app to the foreground is the cost, not the feature. You are holding
/// a bag of shopping; you want to say it and be done.
///
/// So this one runs IN PLACE. `openAppWhenRun = false` with the intent declared in the
/// app target means it runs in the app's own process, launched into the background if it
/// is not already running — which is what lets it reach the same SwiftData store and the
/// same `RunCoordinator` the composer uses, rather than being a second way to send a
/// message.
///
/// What it does is exactly what typing a Tell does: a thread, a user turn, an
/// `OutboxItem` carrying the idempotency key, and a send. If the bridge is not reachable
/// the row simply stays in the outbox and the existing auto-retry drains it when the
/// network comes back — the capture is never lost, and it did not need a queue of its own
/// to say so.
///
/// It speaks nothing. A spoken confirmation of a note is the assistant reading your own
/// words back at you; "Captured" on screen is the whole receipt this deserves.
struct CaptureToJesseIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Jesse"
    /// The whole point — see the type's note.
    static let openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What should I capture?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            return .result(dialog: "There was nothing to capture.")
        }
        JesseCapture.shared.capture(note)
        return .result(dialog: "Captured")
    }
}

/// The in-process capture path `CaptureToJesseIntent` runs on.
///
/// A type of its own rather than code in `perform()`, for the reason every hard-won
/// comment in this app names: the interesting part is what happens on the SECOND run —
/// a capture made while a turn is already in flight, or while the app has no store — and
/// that is only testable if it is somewhere a test can call.
@MainActor
final class JesseCapture {
    nonisolated deinit {}

    static let shared = JesseCapture()

    private let coordinator: () -> RunCoordinator?
    private let context: () -> ModelContext?

    /// The live coordinator when the app is on screen, else a fresh one over the same
    /// store. A background launch has no view tree and therefore no `@Environment`
    /// coordinator, and a capture that only worked with the app open would be a capture
    /// that only worked when you did not need it.
    init(coordinator: @escaping () -> RunCoordinator? = { AppDelegate.delivery.coordinator },
         context: @escaping () -> ModelContext? = {
             ModelContext(AppModelContainer.shared.container)
         }) {
        self.coordinator = coordinator
        self.context = context
    }

    /// Stage the note and send it. Silent about failure by design: a `.failed` outbox row
    /// carries its own Retry and the auto-retry drains it on the next recovery, so there
    /// is nothing here for a person to do and nothing worth saying to them mid-errand.
    func capture(_ note: String) {
        guard let context = context() else { return }
        let thread = JesseThread(mode: .tell)
        context.insert(thread)
        guard let coordinator = coordinator() else {
            // No coordinator in this process — a cold background launch that has not
            // built one. Fall back to the inbox, which the app drains on next appearance.
            JesseInbox.shared.enqueue(mode: .tell, text: note)
            return
        }
        coordinator.send(thread: thread, text: note, voice: false, context: context)
    }
}

struct JesseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // The doorbell first — the reliable hands-free entry. Every phrase leads
        // with the app name (App Shortcuts requires the app-name token in each
        // phrase); `INAlternativeAppNames` gives Siri a distinct spoken name so
        // these don't collide with the Contacts name "Jesse". The reserved verbs
        // "Ask" (→ ChatGPT) and "Tell" (→ Messages) are deliberately NOT used.
        AppShortcut(
            intent: WakeJesseIntent(),
            phrases: [
                "\(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) listen",
                "\(.applicationName) I need you",
                "\(.applicationName) let's talk",
                "\(.applicationName) start listening"
            ],
            shortTitle: "Talk to Jesse",
            systemImageName: "waveform")
        AppShortcut(
            intent: AskJesseIntent(),
            phrases: [
                "\(.applicationName) check the vault",
                "\(.applicationName) check my vault",
                "\(.applicationName) I have a question"
            ],
            shortTitle: "Ask Jesse",
            systemImageName: "questionmark.bubble")
        AppShortcut(
            intent: TellJesseIntent(),
            phrases: [
                "\(.applicationName) update the vault",
                "\(.applicationName) update my vault",
                "\(.applicationName) take a note"
            ],
            shortTitle: "Tell Jesse",
            systemImageName: "text.bubble")
        // The one phrase that does NOT open the app. Same alternative app name as the
        // rest (`INAlternativeAppNames` gives Siri a spoken name distinct from the
        // Contacts entry), so it is a sibling of the three above rather than a
        // separately-addressed thing.
        AppShortcut(
            intent: CaptureToJesseIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "\(.applicationName) capture this"
            ],
            shortTitle: "Capture to Jesse",
            systemImageName: "square.and.arrow.down")
    }
}
