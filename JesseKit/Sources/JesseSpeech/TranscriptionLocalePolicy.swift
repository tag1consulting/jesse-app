import Foundation

/// Which language a recording is transcribed in, and how that question is answered
/// before the user is asked it.
///
/// The driving case for attaching a recording here is Italian, so the locale cannot stay
/// the `en-US` the watch-relay transcriber hardcodes. But "just ask every time" is a
/// tax on the common case, and "always use the phone's language" is wrong for exactly
/// the person this is built for — an English-speaking phone in Italy. So the picker is
/// always offered, and it opens on a defensible answer:
///
///   1. the language used last, if this device still supports it — one choice, then
///      never again for someone who records in one language;
///   2. otherwise the first of the device's own preferred languages that is supported,
///      which is the honest reading of "default sensibly from the device's configured
///      languages" (a phone set to English with Italian second offers Italian the moment
///      English is not available, and English otherwise);
///   3. otherwise anything supported at all, so the picker is never empty when the
///      device can in fact transcribe something.
///
/// All pure, over lists the caller supplies. `SpeechTranscriber.supportedLocales` is an
/// async property on a framework type; passing its result in is what makes every rule
/// here assertable without a speech model installed.
public enum TranscriptionLocalePolicy {
    /// The comparison key for a locale: language plus region, hyphenated and
    /// case-folded, so `it_IT`, `it-IT` and `IT-it` are one key.
    ///
    /// Identifier equality is not usable directly: the same language arrives spelled
    /// three ways depending on whether it came from `Locale.preferredLanguages`, from a
    /// `UserDefaults` round trip, or from the Speech framework.
    public static func key(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier.lowercased() ?? ""
        guard let region = locale.language.region?.identifier.uppercased(), !region.isEmpty else {
            return language
        }
        return "\(language)-\(region)"
    }

    /// The language half of the key: `it-IT` and `it-CH` share `it`.
    public static func languageKey(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier.lowercased() ?? ""
    }

    /// The supported locale that best matches `wanted`: the same language AND region if
    /// there is one, else the same language in any region.
    ///
    /// The language-only fallback is deliberate and is what makes a remembered `it-IT`
    /// keep working on a device that offers only `it-CH`, and what lets a device
    /// preference of bare `it` resolve at all.
    public static func match(_ wanted: Locale, in supported: [Locale]) -> Locale? {
        let wantedKey = key(wanted)
        if let exact = supported.first(where: { key($0) == wantedKey }) { return exact }
        let language = languageKey(wanted)
        guard !language.isEmpty else { return nil }
        return supported.first { languageKey($0) == language }
    }

    /// The locale the picker should open on.
    ///
    /// - Parameters:
    ///   - remembered: the identifier of the last language actually used, if any.
    ///   - preferred: the device's configured languages, most-preferred first
    ///     (`Locale.preferredLanguages`).
    ///   - supported: every locale this device can transcribe.
    /// - Returns: nil only when the device supports nothing at all, which the caller
    ///   surfaces as `TranscriptionFailure.localeUnavailable` rather than as an empty
    ///   picker.
    public static func resolve(remembered: String?,
                               preferred: [String],
                               supported: [Locale]) -> Locale? {
        guard !supported.isEmpty else { return nil }
        if let remembered, !remembered.isEmpty,
           let hit = match(Locale(identifier: remembered), in: supported) {
            return hit
        }
        for identifier in preferred {
            if let hit = match(Locale(identifier: identifier), in: supported) { return hit }
        }
        return supported.first
    }

    /// The name a person reads for a locale, in their own language: "Italian",
    /// "Italiano" for an Italian phone. Falls back to the identifier so the picker can
    /// never render a blank row.
    public static func displayName(_ locale: Locale, in ui: Locale = .current) -> String {
        ui.localizedString(forIdentifier: locale.identifier)
            ?? locale.language.languageCode.flatMap { ui.localizedString(forLanguageCode: $0.identifier) }
            ?? locale.identifier
    }

    /// The picker's rows: the device's own languages first, in the device's preference
    /// order, then everything else alphabetically by the name being shown.
    ///
    /// Speech supports a long list and Italian is nowhere near the top of it
    /// alphabetically; a person whose phone lists English and Italian should not have to
    /// scroll past twenty languages neither they nor their device has ever used.
    /// Duplicates are impossible: a locale is placed by the first preference it matches.
    public static func menu(supported: [Locale],
                            preferred: [String],
                            in ui: Locale = .current) -> [Locale] {
        var remaining = supported
        var head: [Locale] = []
        for identifier in preferred {
            guard let hit = match(Locale(identifier: identifier), in: remaining) else { continue }
            head.append(hit)
            remaining.removeAll { key($0) == key(hit) }
        }
        let tail = remaining.sorted {
            let left = displayName($0, in: ui)
            let right = displayName($1, in: ui)
            return left == right ? key($0) < key($1)
                                 : left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        return head + tail
    }
}
