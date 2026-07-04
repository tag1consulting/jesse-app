import AppIntents
import Combine
import Foundation

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
    static var title: LocalizedStringResource = "Ask Jesse"
    static var openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What's your question?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        JesseInbox.shared.enqueue(mode: .ask, text: text)
        return .result()
    }
}

struct TellJesseIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Jesse"
    static var openAppWhenRun = true

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
    static var title: LocalizedStringResource = "Talk to Jesse"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // A bare wake is an Ask; the captured text runs through the same turn path.
        JesseInbox.shared.enqueueWake(mode: .ask)
        return .result()
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
    }
}
