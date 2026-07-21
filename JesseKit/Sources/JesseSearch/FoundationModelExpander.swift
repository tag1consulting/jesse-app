import Foundation
import FoundationModels
import os

// Tier 2's on-device query expander: the ONLY file in JesseSearch that imports
// FoundationModels. Every other type (and every test) depends on the
// `QueryExpanding` seam instead, so the model dependency is fully contained here
// and the rest of the app never links against a specific model API.
//
// Everything degrades to `[]` (silently off) when the on-device model is
// unavailable for ANY reason (device ineligible, Apple Intelligence off, model
// not yet downloaded) or when a call errors/times out. Nothing is ever sent off
// the device; `SystemLanguageModel` runs entirely on-device.
//
// FoundationModels ships on iOS 26 and macOS 26, so this same expander backs both
// the iPhone and the Mac search. Availability here is about whether the *model* is
// usable at runtime, not whether the framework is present.

/// On-device query-expansion diagnostics: availability and per-call failures,
/// which are swallowed to `[]` and never surfaced to the UI. Package-local so the
/// expander doesn't depend on the app target's logging.
private let searchLog = Logger(subsystem: "com.tag1.jesse", category: "search")

/// Guided-generation output: a small, count-bounded list of alternate search
/// terms. `@Generable` + `@Guide` constrain the model to return exactly this shape.
@Generable
private struct ExpansionTerms {
    @Guide(description: "2 to 4 alternative search terms for the same thing, synonyms, rephrasings, or more/less specific variants",
           .count(2...4))
    var terms: [String]
}

@MainActor
public final class FoundationModelExpander: QueryExpanding {
    /// One reused session (prewarmed on focus), cheaper than a fresh session per
    /// query. Created lazily so an unavailable model never allocates one.
    private var session: LanguageModelSession?

    private static let instructions = """
    You expand a search query into a few alternative search terms for the same \
    thing, synonyms, rephrasings, or more/less specific variants. Reply with the \
    terms only, no explanations.
    """

    public init() {}

    /// `nonisolated` for the same reason as `ThreadSearchModel`'s: under this
    /// module's `.defaultIsolation(MainActor.self)` the synthesized deinit would be
    /// MainActor-isolated, and releasing the expander off the main actor (a unit-test
    /// host tears objects down off-actor) routes through the isolated-deinit executor
    /// hop, which aborts. An empty nonisolated deinit avoids the hop; the `session`
    /// still releases normally afterward. Any class in this target that could be
    /// released off the main actor needs this.
    nonisolated deinit {}

    /// Warm the on-device session when the search field gains focus, so the first
    /// real query doesn't pay cold-start latency. Silent no-op when unavailable.
    public func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        ensureSession().prewarm()
    }

    /// Alternate search terms for `query`, or `[]` when the model is unavailable or
    /// the call fails. Never throws: the search tier treats `[]` as "no expansion".
    public func expand(_ query: String) async -> [String] {
        // Availability FIRST: any unavailable reason -> feature silently off.
        guard case .available = SystemLanguageModel.default.availability else {
            return []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let prompt = """
            Give 2 to 4 alternative search terms for this query, for finding the \
            same thing in a list of past conversations. Terms only. Query: "\(trimmed)"
            """
            let response = try await ensureSession().respond(
                to: prompt, generating: ExpansionTerms.self)
            return filterExpansionTerms(response.content.terms, original: trimmed)
        } catch {
            // Includes timeouts, guardrail rejections, decode failures, all swallowed.
            searchLog.error("query expansion failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(instructions: Self.instructions)
        session = created
        return created
    }
}

/// Pure result-filtering for expansion terms: the unit-testable core of the model
/// path (the real model is unavailable in CI / the Simulator). Trims each term,
/// drops blanks, drops any term equal (case-insensitively) to the original query,
/// de-duplicates case-insensitively, and caps at `maxTerms`. Empty in -> empty out.
///
/// Foundation-only and free of any FoundationModels type, so it is testable from a
/// target that never imports the model framework.
public func filterExpansionTerms(_ raw: [String], original: String, maxTerms: Int = 4) -> [String] {
    let originalKey = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var out: [String] = []
    for term in raw {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        if key == originalKey { continue }
        if out.contains(where: { $0.lowercased() == key }) { continue }
        out.append(trimmed)
        if out.count == maxTerms { break }
    }
    return out
}
