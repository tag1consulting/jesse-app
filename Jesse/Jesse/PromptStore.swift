import Foundation

/// Per-mode custom prompt wrappers, persisted in UserDefaults (these aren't
/// secret, unlike the bearer token, so not Keychain). For each mode we keep
/// four things:
///   * `text`       — what the user typed into the editor
///   * `customized` — an explicit per-mode flag (set when a real override exists)
///   * `default`    — the last bridge default we fetched, used both to compare
///                    against (an override is only sent when it *differs*) and as
///                    the value "Reset to default" restores.
///   * `floor`      — the fixed, non-overridable safety clause the bridge ALWAYS
///                    prepends. Cached purely so Settings can show it read-only;
///                    it never feeds `override(for:)`, the `customized` flag, or
///                    the editor text.
///
/// The invariant the Settings UI surfaces: an empty field always means "use the
/// bridge default" — the override is omitted. (And "Ask" forbids *action* he
/// didn't request, never *writing* a durable fact; that invariant now lives in
/// the bridge's fixed floor, which a custom wrapper cannot drop.)
enum PromptStore {
    private static var defaults: UserDefaults { .standard }

    private static func key(_ mode: JesseMode, _ suffix: String) -> String {
        "jesse.prompt.\(mode.rawValue).\(suffix)"
    }

    // MARK: - Reads

    static func text(_ mode: JesseMode) -> String {
        defaults.string(forKey: key(mode, "text")) ?? ""
    }

    static func customized(_ mode: JesseMode) -> Bool {
        defaults.bool(forKey: key(mode, "customized"))
    }

    static func cachedDefault(_ mode: JesseMode) -> String {
        defaults.string(forKey: key(mode, "default")) ?? ""
    }

    /// The fixed safety floor for a mode, as last fetched from the bridge. Empty
    /// until a fetch populates it. Display-only — see `cacheFloor`.
    static func floor(_ mode: JesseMode) -> String {
        defaults.string(forKey: key(mode, "floor")) ?? ""
    }

    // MARK: - Writes

    /// Cache the bridge default for a mode (after a successful fetch), without
    /// touching the user's text or customized flag.
    static func cacheDefault(_ mode: JesseMode, _ value: String) {
        defaults.set(value, forKey: key(mode, "default"))
    }

    /// Cache the bridge's fixed safety floor for a mode (after a successful
    /// fetch), for read-only display. Deliberately independent of `text`,
    /// `customized`, and `default`: the floor is enforced by the bridge and is
    /// never part of the override the app sends.
    static func cacheFloor(_ mode: JesseMode, _ value: String) {
        defaults.set(value, forKey: key(mode, "floor"))
    }

    /// Persist the editor's `text` and (re)derive the explicit `customized` flag:
    /// a mode is customized when its text is non-empty AND differs from the bridge
    /// default. Pass `default:` to also refresh the cached default (e.g. when it
    /// was just fetched); omit it to compare against the previously cached one.
    static func save(_ mode: JesseMode, text: String, default def: String? = nil) {
        defaults.set(text, forKey: key(mode, "text"))
        if let def { defaults.set(def, forKey: key(mode, "default")) }
        let baseline = def ?? cachedDefault(mode)
        let isCustom = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text != baseline
        defaults.set(isCustom, forKey: key(mode, "customized"))
    }

    /// Reset a mode to the bridge default: text becomes the default, the
    /// customized flag is cleared, and the default is cached. Called by the
    /// per-section "Reset to default" after a successful fetch.
    static func resetToDefault(_ mode: JesseMode, default def: String) {
        defaults.set(def, forKey: key(mode, "default"))
        defaults.set(def, forKey: key(mode, "text"))
        defaults.set(false, forKey: key(mode, "customized"))
    }

    // MARK: - Override decision

    /// The override string to send with a turn, or nil to omit it (use the bridge
    /// default). Non-nil only when the mode is explicitly customized, its text is
    /// non-empty, and it differs from the cached bridge default.
    static func override(for mode: JesseMode) -> String? {
        guard customized(mode) else { return nil }
        let t = text(mode)
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard t != cachedDefault(mode) else { return nil }
        return t
    }
}
