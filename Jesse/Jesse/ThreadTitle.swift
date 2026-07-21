import Foundation
import JesseCore

// Pure, SwiftUI-free helpers for the thread list's AI-generated titles. Kept in
// their own Foundation-only file so they're unit-testable without a view host or
// a network, mirroring ThreadSectioning / ThreadFolders / ThreadSearch.
//
// The row title has two sources, in precedence order:
//   1. `aiTitle` — a short title minted by the bridge's /jesse/title endpoint,
//      cached on the JesseThread and regenerated when the conversation changes.
//   2. the derived first-words title (`JesseThread.deriveTitle`, held in `title`)
//      — the always-available fallback used before (or without) an AI title.
// The AI title is shown even while a refresh is in flight (the last good title,
// never blank), and the derived title stays whenever the bridge can't be reached.
//
// `threadContentKey` is the invalidation seam: a *stable* fingerprint of the
// conversation's turns. When it changes (a turn is appended or edited) the cached
// title's `titleSourceKey` no longer matches, so the title is stale and one
// regeneration is due. `titleDigest` is the bounded, deterministic text the app
// actually sends to the endpoint.

/// Deterministic FNV-1a 64-bit hash of a string's UTF-8 bytes. Used instead of
/// Swift's `hashValue` because that is per-process randomized and so useless for
/// a key we compare across turns (and persist). Pure and stable across launches.
private func fnv1a64(_ s: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// A stable content key for a thread's conversation: an FNV-1a digest over the
/// ordered turns, each contributing its id and a hash of its full text. Same
/// turns → same key; appending a turn or editing one's text → a different key.
/// Deterministic and launch-stable (no `hashValue`). Empty thread → "".
func threadContentKey(for thread: JesseThread) -> String {
    let turns = thread.orderedTurns
    guard !turns.isEmpty else { return "" }
    var acc = ""
    for turn in turns {
        acc += turn.id.uuidString
        acc += ":"
        acc += String(fnv1a64(turn.text))
        acc += "|"
    }
    return String(format: "%016llx", fnv1a64(acc))
}

/// A bounded, deterministic representation of a conversation to send to the title
/// endpoint: the first user message and the most recent turn (typically Jesse's
/// latest reply), each whitespace-collapsed to a single line, joined with " — ",
/// and capped to `maxBytes` on a character boundary — kept well under the bridge's
/// input cap. Deterministic given the same turns; empty thread → "".
func titleDigest(for thread: JesseThread, maxBytes: Int = 2000) -> String {
    let turns = thread.orderedTurns
    guard !turns.isEmpty else { return "" }

    func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    let firstUser = turns.first(where: \.isUser)?.text ?? turns.first!.text
    let latest = turns.last!.text

    // De-duplicate so a single user turn (no reply yet) isn't repeated.
    var parts: [String] = []
    for candidate in [collapse(firstUser), collapse(latest)] where !candidate.isEmpty {
        if !parts.contains(candidate) { parts.append(candidate) }
    }
    return boundedUTF8(parts.joined(separator: " — "), maxBytes: maxBytes)
}

/// Truncate `s` to at most `maxBytes` UTF-8 bytes without splitting a character
/// (so multibyte content is never cut mid-scalar). Pure.
func boundedUTF8(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    var out = ""
    var count = 0
    for ch in s {
        let n = String(ch).utf8.count
        if count + n > maxBytes { break }
        out.append(ch)
        count += n
    }
    return out
}

/// What the list row should display: the cached AI title if present (even while a
/// refresh is in flight — the last good title, never blank), else the derived
/// first-words title, else a placeholder. Never returns an empty string.
func displayTitle(for thread: JesseThread) -> String {
    if let ai = thread.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !ai.isEmpty {
        return ai
    }
    let derived = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return derived.isEmpty ? "New conversation" : derived
}
