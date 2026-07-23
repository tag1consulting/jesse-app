import Foundation

// Per-turn, per-thread, per-device model selection (retiring the global switch). The bridge
// applies a model PER TURN (the request's optional `model` field); each app remembers its own
// choice locally — per conversation and per device — and sends it on every turn. This file
// holds the pieces BOTH apps share so the iPhone and the Mac render one switcher and default a
// new conversation the same way: the selectable-model list, the row-rendering rules, and the
// per-device "last used / default for new conversations" store. Everything here is view-free
// so the SwiftUI menus (iOS `ModelPickerMenu`, macOS `MacModelPickerMenu`) stay thin.

public extension ModelInfo {
    /// The one-line label a switcher row shows: the human label, plus a parenthetical reason
    /// when the model is NOT selectable ("not configured" / "unreachable"), so both apps render
    /// an identical, self-explaining disabled row. Selection is gated on `available` by the
    /// caller; this is display only.
    var menuRowLabel: String {
        if let reason = unavailableReason { return "\(label) — \(reason)" }
        return label
    }
}

public extension ModelSwitchState {
    /// The models to OFFER in a switcher, in registry order — ALL of them, so an unavailable
    /// model renders disabled (with `menuRowLabel`'s reason) rather than vanishing. The caller
    /// gates selection on each model's `available`.
    var offered: [ModelInfo] { models }

    /// Just the models selectable RIGHT NOW (configured AND healthy). Used to default a new
    /// conversation and to validate a stored per-thread/per-device id still resolves.
    var selectable: [ModelInfo] { models.filter { $0.available } }

    /// The always-available ambient default (`opus`), if present in this list.
    var defaultModel: ModelInfo? { models.first { $0.isDefault } }

    /// Resolve the model that should back a turn, preferring the thread's own stored selection,
    /// then this device's default (last used), then the ambient default (`opus`), then any
    /// selectable model. A stored id that is no longer selectable is skipped, so the app never
    /// sends a turn onto a model the bridge would reject — the switcher then shows the fallback.
    /// Returns `nil` only when the list has nothing selectable at all (no models loaded yet).
    func resolvedModel(threadModelID: String?, deviceDefaultID: String?) -> ModelInfo? {
        func pick(_ id: String?) -> ModelInfo? {
            guard let id else { return nil }
            return models.first { $0.id == id && $0.available }
        }
        return pick(threadModelID)
            ?? pick(deviceDefaultID)
            ?? (defaultModel?.available == true ? defaultModel : nil)
            ?? selectable.first
    }
}

/// Resolves what a model SWITCHER BUTTON should show for the next turn — usable even before the
/// model list has loaded (or when it never loads: an older bridge / a persistent fetch failure).
/// View-free so the iOS and macOS composer pickers share one label rule and neither hides the
/// control on a nil/failed fetch. Selection is still gated on a model's `available` by the caller;
/// this decides only the label and the resolved id.
public enum ModelSelectionResolver {
    /// The ambient default's id (`opus`), the last-ditch fallback when nothing is stored and no
    /// list has loaded. Matches the bridge's always-available ambient model (`kind == "ambient"`).
    public static let ambientDefaultID = "opus"

    /// The id the next turn will run on — independent of whether the list has loaded: the thread's
    /// own stored selection, else this device's default (last used), else the ambient default.
    public static func resolvedID(threadModelID: String?, deviceDefaultID: String?) -> String {
        if let id = threadModelID?.trimmedNonEmpty { return id }
        if let id = deviceDefaultID?.trimmedNonEmpty { return id }
        return ambientDefaultID
    }

    /// The human label the button shows: when the list has loaded, the resolved model's label
    /// (which also skips a stored-but-now-unavailable id, matching `resolvedModel`); before the
    /// list loads — or if it never does — the resolved id itself, so the control is never blank
    /// and never hidden. `state == nil` is the slow / failed / older-bridge case.
    public static func resolvedLabel(state: ModelSwitchState?,
                                     threadModelID: String?, deviceDefaultID: String?) -> String {
        if let state,
           let model = state.resolvedModel(threadModelID: threadModelID,
                                           deviceDefaultID: deviceDefaultID) {
            return model.label
        }
        return resolvedID(threadModelID: threadModelID, deviceDefaultID: deviceDefaultID)
    }
}

private extension String {
    /// The trimmed value, or `nil` when blank — so a stored empty/whitespace id reads as "unset".
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// The per-DEVICE model default: the model a NEW conversation starts on, updated to the last
/// model the user picked on this device (and settable directly from Settings as "Default model
/// for new conversations on this device"). Backed by `UserDefaults` so it is naturally
/// per-device — the iPhone and the Mac keep independent defaults — and never touches the
/// bridge's server-side default. `nil` means "none chosen yet" (a new conversation then falls
/// back to the ambient `opus`).
public enum LastUsedModelStore {
    /// Overridable so tests (and the Mac/iOS app groups, if ever needed) can point at a scratch
    /// suite instead of `.standard`. Defaults to the standard user defaults.
    public static let defaultsKey = "jesse.lastUsedModelID"

    private static var defaults: UserDefaults { .standard }

    /// The last model id chosen on this device, or `nil` when none has been chosen. A blank or
    /// whitespace-only stored value normalizes to `nil`.
    public static var id: String? {
        get {
            let v = defaults.string(forKey: defaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set {
            let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v, !v.isEmpty {
                defaults.set(v, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }
}
