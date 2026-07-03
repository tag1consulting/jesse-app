import Foundation
import Observation

// Search orchestration for the query-expansion tier (Tier 2). Sits between the
// live search field and the pure predicates: it decides WHEN to ask the injected
// `QueryExpanding` for alternate terms, coalesces rapid typing, caches, cancels
// stale work, and publishes the currently-active alternate terms for the view to
// union with the typed query.
//
// The contract is efficiency + silent fallback:
//   * DEBOUNCE  — wait ~300ms of quiet before spending the model, so a burst of
//     keystrokes is one call, not one per character.
//   * GATE      — never call the model for a trivial query or when the base match
//     set is already plentiful (`shouldExpand`).
//   * CACHE     — a session-scoped LRU keyed by the normalized query, so a repeat
//     or a backspaced-then-retyped query is expanded at most once.
//   * CANCEL    — a query change cancels the in-flight expansion (structured Task
//     cancellation), so terms for a query the user has moved on from are never
//     applied.
//   * PUBLISH   — `activeTerms` is the alternate list for the current query, empty
//     whenever search is idle, gated off, or the expander returned nothing.
//
// The model never blocks the list: the view filters on the typed query immediately
// and simply widens the set if/when `activeTerms` becomes non-empty.
@MainActor
@Observable
final class ThreadSearchModel {
    /// Alternate search terms currently active for the live query. The view unions
    /// these with the typed query (`threadMatchesAny`). Empty when idle/gated/dry.
    private(set) var activeTerms: [String] = []

    /// Master on/off for the whole expansion tier (the Settings toggle). When off,
    /// `update` never calls the expander — pure Tier-1 search — and any published
    /// terms are cleared immediately.
    var isEnabled: Bool {
        didSet { if !isEnabled { clear() } }
    }

    private let expander: QueryExpanding
    private let debounce: Duration
    private let threshold: Int
    private let cacheCapacity: Int

    /// LRU cache of normalized query → expansion terms. `lruOrder` is most-recent
    /// last; on capacity the front (least-recent) entry is evicted.
    private var cache: [String: [String]] = [:]
    private var lruOrder: [String] = []

    /// The normalized query the currently-published `activeTerms` belong to, and
    /// the in-flight expansion task (plus the query it is expanding, so a repeat of
    /// the same query doesn't spawn a second call).
    private var currentQuery = ""
    private var task: Task<Void, Never>?
    private var taskQuery: String?

    /// `threshold` is the base-match count at/above which expansion is skipped
    /// (plenty of direct hits already). Debounce/cache size are injectable so tests
    /// stay deterministic and fast.
    init(expander: QueryExpanding,
         isEnabled: Bool = true,
         debounce: Duration = .milliseconds(300),
         threshold: Int = 5,
         cacheCapacity: Int = 32) {
        self.expander = expander
        self.isEnabled = isEnabled
        self.debounce = debounce
        self.threshold = threshold
        self.cacheCapacity = cacheCapacity
    }

    /// Feed the live query text and the CURRENT base-match count (threads matching
    /// the typed query alone). Debounces, gates, caches, and cancels as described.
    /// Safe to call on every keystroke and on every base-count change.
    func update(query: String, baseMatchCount: Int) {
        let normalized = normalize(query)

        // A different query invalidates any in-flight expansion for the old one:
        // cancel it so its (now stale) terms can never be applied.
        if normalized != currentQuery {
            task?.cancel()
            task = nil
            taskQuery = nil
        }
        currentQuery = normalized

        // Tier disabled (Settings toggle off) → pure Tier-1, never call the model.
        guard isEnabled else {
            activeTerms = []
            return
        }

        // Search idle → no terms, no work.
        if normalized.isEmpty {
            activeTerms = []
            return
        }

        // Gate: trivial query or already-plentiful base results → don't spend the
        // model, and clear any terms carried over from a previous query.
        guard shouldExpand(query: normalized, baseMatchCount: baseMatchCount,
                           threshold: threshold) else {
            activeTerms = []
            return
        }

        // Cache hit → apply immediately, no expander call.
        if let cached = cachedTerms(for: normalized) {
            activeTerms = cached
            return
        }

        // Already expanding exactly this query → let it finish (no duplicate call).
        if taskQuery == normalized, task != nil { return }

        // Miss → debounce, then a single expander call; apply only if still current.
        taskQuery = normalized
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            if Task.isCancelled { return }
            let terms = await self.expander.expand(normalized)
            if Task.isCancelled { return }
            self.applyExpansion(terms, for: normalized)
        }
    }

    /// Warm the expander (on search-field focus) so the first query doesn't pay
    /// cold-start latency. Forwards to the injected expander's optional `prewarm`.
    func prewarm() {
        expander.prewarm()
    }

    /// Clear all state (search dismissed). Cancels any in-flight expansion.
    func clear() {
        task?.cancel()
        task = nil
        taskQuery = nil
        currentQuery = ""
        activeTerms = []
    }

    /// Test hook: await the in-flight expansion (if any) so assertions run after
    /// the debounce + expander call have settled. No-op when nothing is in flight.
    func awaitPendingExpansion() async {
        await task?.value
    }

    // MARK: - Internals

    /// Fold the expander's result into the cache and publish it — but only if the
    /// user is still on this query (a change since the call started drops it).
    private func applyExpansion(_ terms: [String], for query: String) {
        store(terms, for: query)
        guard query == currentQuery else { return }
        activeTerms = terms
        taskQuery = nil
    }

    /// Case/whitespace-normalized cache + identity key for a query.
    private func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func cachedTerms(for key: String) -> [String]? {
        guard let terms = cache[key] else { return nil }
        touch(key)
        return terms
    }

    private func store(_ terms: [String], for key: String) {
        cache[key] = terms
        touch(key)
        // Evict least-recently-used entries beyond capacity.
        while lruOrder.count > cacheCapacity {
            let evict = lruOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    /// Move `key` to the most-recent end of the LRU order.
    private func touch(_ key: String) {
        if let i = lruOrder.firstIndex(of: key) { lruOrder.remove(at: i) }
        lruOrder.append(key)
    }
}
