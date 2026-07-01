import Foundation

// Pure, SwiftUI-free row-preview text for the thread list. Kept in its own file
// (Foundation only) so it is unit-testable without a view host, mirroring
// ThreadSectioning.
//
// The list row's first line is the derived title (the first ~60 chars of the
// FIRST user message), which never changes so favorites stay recognizable by
// their opening words. This preview is a SECOND line that hints at where the
// conversation actually went: a single-line, whitespace-collapsed snippet of
// the LATEST turn (Jesse's most recent reply, or the last user turn if there is
// no reply yet). An empty thread (no turns) has no preview.

/// A one-line, whitespace-collapsed snippet of the thread's latest turn, or ""
/// when the thread has no turns.
func rowPreview(for thread: JesseThread) -> String {
    guard let latest = thread.orderedTurns.last else { return "" }
    // Collapse every run of whitespace/newlines to a single space so the snippet
    // stays on one line regardless of the reply's internal formatting.
    return latest.text
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}
