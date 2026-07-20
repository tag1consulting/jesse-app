import Foundation

/// Per-mode custom prompts, persisted in UserDefaults (these aren't secret,
/// unlike the bearer token, so not Keychain). Each mode has two *slots*:
///
///   * `.wrapper` — the editable framing that wraps your message (freely
///     editable, no unlock). This is the long-standing override.
///   * `.floor`   — the safety clause the bridge ALWAYS prepends. Now an
///     *unlockable* override slot (locked by default in Settings, editable
///     behind an explicit "not recommended" gate), not display-only. An empty
///     floor override means "use the bridge's built-in floor" — the floor is
///     never removed; the worst a customization can do is reword it.
///
/// For each (mode, slot) we keep four things:
///   * `text`       — what the user typed into the editor
///   * `customized` — an explicit flag (set when a real override exists)
///   * `default`    — the last bridge default we fetched, used both to compare
///                    against (an override is only sent when it *differs*) and as
///                    the value "Reset to default" restores.
///
/// The invariant the Settings UI surfaces: an empty field always means "use the
/// bridge default" — the override is omitted. (And "Ask" forbids *action* he
/// didn't request, never *writing* a durable fact; that invariant lives in the
/// bridge's floor, which a custom wrapper cannot drop and an empty floor
/// override falls back to.)
enum PromptStore {
    private static var defaults: UserDefaults { .standard }

    /// Which prompt a key addresses for a mode. The wrapper keeps the original,
    /// un-suffixed keys (`jesse.prompt.<mode>.<suffix>`) for back-compat so saved
    /// wrapper overrides survive; the floor nests under a `.floor` segment.
    enum PromptSlot: String {
        case wrapper
        case floor

        /// The key-path segment inserted before the suffix. Empty for the wrapper
        /// (back-compat), `"floor."` for the floor.
        var keySegment: String {
            switch self {
            case .wrapper: return ""
            case .floor: return "floor."
            }
        }
    }

    private static func key(_ mode: JesseMode, _ slot: PromptSlot, _ suffix: String) -> String {
        "jesse.prompt.\(mode.rawValue).\(slot.keySegment)\(suffix)"
    }

    // MARK: - Owner name

    /// UserDefaults key for the owner's display name — the personalization the app
    /// threads into locally-built prompt context (e.g. the diet-coach rollup).
    private static let ownerNameKey = "jesse.owner.name"

    /// How the app refers to the owner in prompt context it builds itself. Default
    /// "the user" (the generic identity a fresh install reads with). Set it in
    /// Settings to a real name; the bridge's own wrappers are personalized
    /// separately via its `jesse.local.toml` persona. A blank value reads as the
    /// default so an empty field never sends "".
    static var ownerName: String {
        get {
            let v = (defaults.string(forKey: ownerNameKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? "the user" : v
        }
        set {
            defaults.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: ownerNameKey
            )
        }
    }

    // MARK: - Reads

    static func text(_ mode: JesseMode, _ slot: PromptSlot) -> String {
        defaults.string(forKey: key(mode, slot, "text")) ?? ""
    }

    static func customized(_ mode: JesseMode, _ slot: PromptSlot) -> Bool {
        defaults.bool(forKey: key(mode, slot, "customized"))
    }

    static func cachedDefault(_ mode: JesseMode, _ slot: PromptSlot) -> String {
        defaults.string(forKey: key(mode, slot, "default")) ?? ""
    }

    // MARK: - Writes

    /// Cache the bridge default for a (mode, slot) after a successful fetch,
    /// without touching the user's text or customized flag.
    static func cacheDefault(_ mode: JesseMode, _ slot: PromptSlot, _ value: String) {
        defaults.set(value, forKey: key(mode, slot, "default"))
    }

    /// Persist the editor's `text` and (re)derive the explicit `customized` flag:
    /// a slot is customized when its text is non-empty AND differs from the bridge
    /// default. Pass `default:` to also refresh the cached default (e.g. when it
    /// was just fetched); omit it to compare against the previously cached one.
    static func save(_ mode: JesseMode, _ slot: PromptSlot, text: String, default def: String? = nil) {
        defaults.set(text, forKey: key(mode, slot, "text"))
        if let def { defaults.set(def, forKey: key(mode, slot, "default")) }
        let baseline = def ?? cachedDefault(mode, slot)
        let isCustom = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text != baseline
        defaults.set(isCustom, forKey: key(mode, slot, "customized"))
    }

    /// Reset a (mode, slot) to the bridge default: text becomes the default, the
    /// customized flag is cleared, and the default is cached. Called by the
    /// per-section "Reset to default" after a successful fetch.
    static func resetToDefault(_ mode: JesseMode, _ slot: PromptSlot, default def: String) {
        defaults.set(def, forKey: key(mode, slot, "default"))
        defaults.set(def, forKey: key(mode, slot, "text"))
        defaults.set(false, forKey: key(mode, slot, "customized"))
    }

    // MARK: - Override decision

    /// The override string to send with a turn for a (mode, slot), or nil to omit
    /// it (use the bridge default). Non-nil only when the slot is explicitly
    /// customized, its text is non-empty, and it differs from the cached default.
    static func override(for mode: JesseMode, _ slot: PromptSlot) -> String? {
        guard customized(mode, slot) else { return nil }
        let t = text(mode, slot)
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard t != cachedDefault(mode, slot) else { return nil }
        return t
    }

    /// The wrapper override for a mode, or nil to use the bridge default.
    static func wrapperOverride(for mode: JesseMode) -> String? {
        override(for: mode, .wrapper)
    }

    /// The floor override for a mode, or nil to use the bridge's built-in floor.
    /// An empty/absent floor override never removes the floor — the bridge falls
    /// back to its const.
    static func floorOverride(for mode: JesseMode) -> String? {
        override(for: mode, .floor)
    }
}
