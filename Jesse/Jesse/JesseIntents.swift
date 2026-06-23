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

// Cross-launch hand-off: UserDefaults survives a cold launch; the @Published
// property makes a warm hand-off instant. ContentView drains it on becoming active.
final class JesseInbox: ObservableObject {
    static let shared = JesseInbox()
    @Published var pending: PendingVoiceRequest?

    private let dMode = "jesse.pending.mode"
    private let dText = "jesse.pending.text"

    func enqueue(mode: JesseMode, text: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: dMode)
        UserDefaults.standard.set(text, forKey: dText)
        DispatchQueue.main.async { self.drain() }
    }

    /// Pick up a queued voice request (call on launch/foreground).
    func drain() {
        guard let m = UserDefaults.standard.string(forKey: dMode),
              let mode = JesseMode(rawValue: m),
              let text = UserDefaults.standard.string(forKey: dText),
              !text.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: dMode)
        UserDefaults.standard.removeObject(forKey: dText)
        pending = PendingVoiceRequest(mode: mode, text: text)
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

struct JesseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJesseIntent(),
            phrases: [
                "\(.applicationName) check the vault",
                "\(.applicationName) check my vault",
                "\(.applicationName) I have a question",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask Jesse",
            systemImageName: "questionmark.bubble")
        AppShortcut(
            intent: TellJesseIntent(),
            phrases: [
                "\(.applicationName) update the vault",
                "\(.applicationName) update my vault",
                "\(.applicationName) take a note",
                "Tell \(.applicationName)"
            ],
            shortTitle: "Tell Jesse",
            systemImageName: "text.bubble")
    }
}
