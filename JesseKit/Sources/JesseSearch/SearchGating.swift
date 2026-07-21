import Foundation

// The Tier-2 expansion GATING decision: pure, deterministic, view-free, so both
// the orchestration model and its tests can reason about WHEN the on-device query
// expander is worth invoking without a real model or a view host. Extracted into
// the shared JesseSearch library so iOS and macOS gate the expansion tier the same
// way (the pure multi-token match predicate itself lives in JesseConversations).

/// Whether the query expansion tier is worth invoking. True only when the trimmed
/// query is a real token (length >= 3, so trivial 1 to 2 character queries never
/// spend the model) AND the base matcher already found fewer than `threshold`
/// threads (so a plentiful result set is never widened). Pure and deterministic.
public func shouldExpand(query: String, baseMatchCount: Int, threshold: Int) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 3 else { return false }
    return baseMatchCount < threshold
}
