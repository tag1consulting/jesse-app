import Foundation

// WHAT THE MODEL IS SHOWN, AND WHY IT IS SO LITTLE.
//
// Retrieval first, model last. The index already knows where the answer is — that is
// what an inverted index over seven thousand notes IS — and the model's entire job is
// to read four paragraphs and say which sentence answers the question. Every line here
// exists to make those four paragraphs the right four and to keep them inside a budget
// this device actually has.
//
// THE BUDGET IS MEASURED, NOT ASSUMED. `ModelProbe` grows a prompt on the real device
// until the session refuses it. That number (33,500 characters on the phone, 21,000 on
// the Mac, measured 2026-09-22) is persisted by the diagnostics screen and read here.
// Absent it, the fallback is deliberately small rather than optimistic: a prompt that
// is refused is not a degraded answer, it is no answer at all.
//
// TWO ORDERS, FUSED. bm25 knows about words; a sentence embedding knows that "concert"
// and "recital" are the same thing and that a note about a brick order is not about
// either. Neither is reliable alone, and choosing between them per query is a tuning
// problem nobody can see the inputs to, so both orders are computed and combined by
// reciprocal rank fusion — which needs only the RANKS, never a calibration between two
// score scales that have nothing to do with each other. With no embedding available,
// bm25's order simply stands.
//
// `Inbox/` IS NEVER RETRIEVED FROM. It holds pasted mail and scan output: text written
// by other people, sitting in the vault, that would otherwise be lifted verbatim into a
// model prompt. Excluding it is not tidiness, it is the boundary that keeps this path
// from reading instructions off an email.

/// One chunk, retrieved whole, with the two facts that let a citation open it.
public struct RetrievedChunk: Equatable, Sendable {
    /// Path relative to the vault root — the citation's identity.
    public let path: String
    /// The 1-based line the chunk starts at.
    public let line: Int
    public let title: String
    public let heading: String
    /// The chunk's body, clipped to its share of the budget.
    public let text: String

    public init(path: String, line: Int, title: String, heading: String, text: String) {
        self.path = path
        self.line = line
        self.title = title
        self.heading = heading
        self.text = text
    }

    /// `Workshop/Kiln-Rebuild.md:12` — how the prompt names a note and how a citation
    /// is displayed.
    public var reference: String { "\(path):\(line)" }
}

/// Similarity between two pieces of text, as the re-ranker needs it.
///
/// A seam for the same reason every model dependency in this package is one: the real
/// implementation links a framework, and a test must be able to state "this chunk is
/// closer than that one" without one.
public protocol ChunkEmbedding: Sendable {
    /// False when this device has no sentence embedding, in which case bm25's order
    /// stands and nothing is re-ranked.
    var isAvailable: Bool { get }
    /// Cosine similarity in roughly -1...1, higher meaning closer. Nil for a pair the
    /// embedding cannot place, which is treated as "no opinion" rather than as zero.
    func similarity(_ lhs: String, _ rhs: String) -> Double?
}

/// No embedding on this device. bm25 alone, which is a complete answer and not a
/// degraded one.
public struct NoChunkEmbedding: ChunkEmbedding {
    public init() {}
    public var isAvailable: Bool { false }
    public func similarity(_ lhs: String, _ rhs: String) -> Double? { nil }
}

/// How many chunks, and how many characters of them.
public struct VaultRetrievalBudget: Equatable, Sendable {
    /// How many chunks go in the prompt.
    public let chunkCount: Int
    /// The ceiling on all of their text together.
    public let totalCharacters: Int

    public init(chunkCount: Int, totalCharacters: Int) {
        self.chunkCount = max(1, chunkCount)
        self.totalCharacters = max(1, totalCharacters)
    }

    /// One chunk's share. Equal shares rather than "fill greedily from the top",
    /// because a greedy fill lets one long chunk eat the other three — and the fourth
    /// chunk is disproportionately often the one with the date in it.
    public var perChunkCharacters: Int {
        max(1, totalCharacters / chunkCount)
    }

    /// Four chunks, or two on a device whose measured window is small.
    public static let defaultChunkCount = 4
    public static let smallChunkCount = 2
    /// Below this measured maximum, four chunks cannot each be long enough to be worth
    /// sending, so the count halves and each one gets a real share instead.
    public static let smallWindowCharacters = 6_000
    /// The share of the measured maximum the snippets may spend. The rest is the
    /// question, the instructions, and the answer the model still has to produce.
    public static let snippetShare = 0.6
    /// What is used when the probe has never been run on this device. Deliberately
    /// below the smallest window measured so far rather than at it.
    public static let unmeasuredCharacters = 12_000

    /// The budget implied by the probe's measured maximum prompt size.
    public static func forMeasuredPrompt(_ measured: Int?) -> VaultRetrievalBudget {
        guard let measured, measured > 0 else {
            return VaultRetrievalBudget(chunkCount: defaultChunkCount,
                                        totalCharacters: unmeasuredCharacters)
        }
        let count = measured < smallWindowCharacters ? smallChunkCount : defaultChunkCount
        return VaultRetrievalBudget(chunkCount: count,
                                    totalCharacters: Int(Double(measured) * snippetShare))
    }

    /// The sentence the Settings row shows, so the number and what it implies are never
    /// two separate claims a reader has to reconcile.
    public static func describe(_ measured: Int?) -> String {
        let budget = forMeasuredPrompt(measured)
        guard let measured else {
            return "Prompt size not measured — using \(budget.chunkCount) note extracts, "
                + "\(budget.totalCharacters) characters."
        }
        return "Measured prompt size \(measured) characters — using \(budget.chunkCount) "
            + "note extracts, \(budget.totalCharacters) characters."
    }
}

/// Reciprocal rank fusion. Pure, and stated over ranks alone.
public enum RankFusion {
    /// The constant that decides how fast a rank's contribution decays. 60 is the
    /// value the method was published with and the value every later comparison is
    /// stated against; it is not tuned here, because tuning it against a fixture
    /// corpus would be fitting a constant to six invented notes.
    public static let k = 60.0

    /// Fuse several orderings of the same items into one.
    ///
    /// Each ordering is a list of keys, best first. An item absent from an ordering
    /// simply contributes nothing from it, which is what makes a partial second
    /// opinion usable: the embedding can decline to place a chunk without that chunk
    /// being pushed to the bottom.
    public static func fuse(_ orderings: [[String]]) -> [String: Double] {
        var scores: [String: Double] = [:]
        for ordering in orderings {
            for (index, key) in ordering.enumerated() {
                scores[key, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores
    }
}

/// The chunks one question gets answered from.
public struct VaultRetriever: Sendable {
    /// How many hits the search asks for before re-ranking. Twenty rather than the
    /// four that survive, because the fusion has to have something to reorder.
    public static let searchLimit = 20
    /// Below this many base hits the expansion tier is worth spending — the same
    /// threshold the conversation list and the vault search already use.
    public static let expansionThreshold = 5
    /// The one directory that is never retrieved from, with its whole subtree.
    public static let excludedPrefix = "Inbox/"

    private let index: VaultIndex
    private let expander: any VaultQueryExpanding
    private let embedding: any ChunkEmbedding

    public init(index: VaultIndex,
                expander: any VaultQueryExpanding = NoVaultExpansion(),
                embedding: any ChunkEmbedding = NoChunkEmbedding()) {
        self.index = index
        self.expander = expander
        self.embedding = embedding
    }

    /// What one question retrieved, and what it cost — the numbers the diagnostics
    /// list shows, kept beside the chunks so a row can never describe a different run.
    public struct Result: Sendable {
        public let chunks: [RetrievedChunk]
        /// Hits the search returned, after the `Inbox/` exclusion.
        public let hitCount: Int
        /// Whether a sentence embedding actually contributed an ordering.
        public let embedded: Bool

        public init(chunks: [RetrievedChunk], hitCount: Int, embedded: Bool) {
            self.chunks = chunks
            self.hitCount = hitCount
            self.embedded = embedded
        }

        /// The characters actually put in front of the model.
        public var characters: Int { chunks.reduce(0) { $0 + $1.text.count } }
    }

    /// Retrieve, re-rank, and clip to `budget`.
    ///
    /// THREE PASSES, WIDENING, and the first one that finds enough wins. The vault
    /// search requires EVERY token of a query to be present — which is right for a
    /// search field, where the person is choosing the words, and wrong for a typed
    /// question, where "when is the school concert" would require a note containing the
    /// word "when". So:
    ///
    ///   1. The question's KEYWORDS, all of them. The precise pass; when it hits, it is
    ///      the right note.
    ///   2. The same keywords through the app's own expander, which is the tier the
    ///      conversation list and the vault search already use, on the same threshold.
    ///   3. EACH KEYWORD ALONE, longest first, unioned in behind whatever the first two
    ///      found. This is the pass that makes an ordinary spoken question work at all,
    ///      and it can only ADD — nothing found by a more precise pass is displaced.
    public func retrieve(question: String, budget: VaultRetrievalBudget) async -> Result {
        let searcher = VaultSearcher(index: index,
                                     expansionThreshold: Self.expansionThreshold,
                                     limit: Self.searchLimit)
        let keywords = LookupQuery.keywords(question)
        let query = keywords.joined(separator: " ")

        var hits = Self.allowed(searcher.base(query).hits)
        if hits.count < Self.expansionThreshold {
            hits = Self.allowed(await searcher.search(query, expander: expander).hits)
        }
        if hits.count < Self.expansionThreshold, keywords.count > 1 {
            var seen = Set(hits.map(\.path))
            for keyword in keywords.sorted(by: { $0.count > $1.count }) {
                for hit in Self.allowed(searcher.base(keyword).hits)
                where !seen.contains(hit.path) {
                    seen.insert(hit.path)
                    hits.append(hit)
                }
            }
        }
        hits = Array(hits.prefix(Self.searchLimit))
        guard !hits.isEmpty else {
            return Result(chunks: [], hitCount: 0, embedded: false)
        }

        // The snippet a hit carries is fifteen words around the match. The BODY is what
        // gets read, so a hit whose chunk is no longer in the index (a reindex between
        // the search and this read) is dropped rather than sent as its own snippet.
        var bodies: [(hit: VaultSearchHit, text: String)] = []
        for hit in hits {
            guard let body = index.chunkText(path: hit.path, line: hit.line),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            bodies.append((hit, body))
        }
        guard !bodies.isEmpty else {
            return Result(chunks: [], hitCount: hits.count, embedded: false)
        }

        let ordered = Self.fused(bodies, question: question, embedding: embedding)
        let kept = ordered.prefix(budget.chunkCount)
        let chunks = kept.map { entry in
            RetrievedChunk(path: entry.hit.path,
                           line: entry.hit.line,
                           title: entry.hit.title,
                           heading: entry.hit.heading,
                           text: Self.clip(entry.text, to: budget.perChunkCharacters))
        }
        return Result(chunks: Array(chunks), hitCount: hits.count,
                      embedded: embedding.isAvailable)
    }

    // MARK: - Pure halves, asserted directly

    /// Everything outside `Inbox/`, in the order it arrived.
    public static func allowed(_ hits: [VaultSearchHit]) -> [VaultSearchHit] {
        hits.filter { !$0.path.hasPrefix(excludedPrefix) }
    }

    /// The bm25 order and the embedding order, fused.
    ///
    /// The embedding is asked only when it says it is available, and a pair it cannot
    /// place is left out of its ordering entirely rather than scored zero — zero is a
    /// real similarity and would rank such a chunk above genuinely dissimilar ones.
    static func fused(_ bodies: [(hit: VaultSearchHit, text: String)],
                      question: String,
                      embedding: any ChunkEmbedding) -> [(hit: VaultSearchHit, text: String)] {
        let keys = bodies.map { "\($0.hit.path)#\($0.hit.line)" }
        var orderings = [keys]

        if embedding.isAvailable {
            var scored: [(key: String, score: Double)] = []
            for (index, body) in bodies.enumerated() {
                if let score = embedding.similarity(question, body.text) {
                    scored.append((keys[index], score))
                }
            }
            if !scored.isEmpty {
                // Ties break on the bm25 position, so the fusion is deterministic for a
                // corpus where several chunks embed identically.
                let position = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
                let order = scored.sorted {
                    $0.score == $1.score ? (position[$0.key] ?? 0) < (position[$1.key] ?? 0)
                                         : $0.score > $1.score
                }.map(\.key)
                orderings.append(order)
            }
        }

        let scores = RankFusion.fuse(orderings)
        let position = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        return bodies.enumerated().sorted { lhs, rhs in
            let a = scores[keys[lhs.offset]] ?? 0
            let b = scores[keys[rhs.offset]] ?? 0
            if a != b { return a > b }
            return (position[keys[lhs.offset]] ?? 0) < (position[keys[rhs.offset]] ?? 0)
        }.map(\.element)
    }

    /// One chunk's text, at most `limit` characters.
    ///
    /// Clipped on a whitespace boundary when there is one within the last fifth of the
    /// allowance, so a chunk does not end mid-word — a half word at the end of a note
    /// extract is the kind of thing a small model completes rather than ignores.
    public static func clip(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        let floor = head.index(head.startIndex, offsetBy: (limit * 4) / 5)
        if let breakPoint = head.lastIndex(where: { $0.isWhitespace }), breakPoint > floor {
            return String(head[head.startIndex..<breakPoint])
        }
        return String(head)
    }
}

/// A TYPED QUESTION IS NOT A SEARCH QUERY, and this is the difference.
///
/// `VaultSearchQuery` requires every token: a search field's rule, and the right one,
/// because the person typing into it chose those words. A question chooses its words for
/// a human listener, and most of them are grammar — "when", "is", "the", "did", "we".
/// Requiring a note to contain "when" is requiring the wrong thing.
///
/// Pure, and deliberately dumb: no stemming, no synonyms, no weighting. The expander
/// tier above already does the clever half, and a clever tokenizer here would be a
/// second, invisible one that disagreed with it.
public enum LookupQuery {

    /// Words that carry no retrieval signal in a question.
    ///
    /// Question words and auxiliaries, not a general English stop list: "no" and "not"
    /// stay, because a note that says a thing did NOT happen is exactly the note wanted,
    /// and so do short nouns that a general list would eat.
    public static let stopWords: Set<String> = [
        "a", "about", "all", "am", "an", "and", "any", "are", "as", "at", "be", "been",
        "but", "by", "can", "could", "did", "do", "does", "for", "from", "get", "give",
        "had", "has", "have", "he", "her", "hers", "him", "his", "how", "i", "if", "in",
        "into", "is", "it", "its", "may", "me", "mine", "much", "must", "my", "of", "on",
        "or", "our", "ours", "out", "over", "please", "she", "should", "so", "some",
        "tell", "than", "that", "the", "their", "theirs", "them", "then", "there",
        "these", "they", "this", "those", "to", "up", "us", "was", "we", "were", "what",
        "when", "where", "which", "who", "whom", "whose", "why", "will", "with", "would",
        "you", "your", "yours",
    ]

    /// The words worth searching for, in the order they were typed.
    ///
    /// Falls back to the question's own tokens when every word is a stop word ("what is
    /// it"), because an empty query retrieves nothing and "nothing" is a worse answer
    /// than a bad one here — the abstain downstream is what catches a bad one.
    public static func keywords(_ question: String) -> [String] {
        let tokens = VaultSearchQuery.tokens(question)
        let kept = tokens.filter { !stopWords.contains($0.lowercased()) }
        return kept.isEmpty ? tokens : kept
    }
}
