import Foundation
import NaturalLanguage

// THE ONLY FILE IN THIS PACKAGE THAT IMPORTS NaturalLanguage.
//
// A sentence embedding is the cheapest thing on this device that knows "concert" and
// "recital" are the same question, and it costs no download, no model load anyone can
// see, and no network. It is also not always there: `sentenceEmbedding(for:)` returns
// nil on a system without the asset, and it is English-only, which is why everything
// above it treats a missing embedding as an ORDINARY state and simply keeps bm25's
// order rather than degrading.
//
// Loaded LAZILY and once. Building the embedding is tens of milliseconds and the
// offline answer path may never run on a given launch; a stored property would pay for
// it on every app start for a feature most launches never touch.

/// `NLEmbedding`'s sentence space, behind the `ChunkEmbedding` seam.
public final class NaturalLanguageChunkEmbedding: ChunkEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?

    public init() {}

    public var isAvailable: Bool { resolve() != nil }

    /// Cosine similarity, from `NLEmbedding`'s cosine DISTANCE.
    ///
    /// `distance(between:and:)` answers `Double.greatestFiniteMagnitude` for a string it
    /// cannot place, and that value must not be turned into a similarity of minus
    /// infinity and ranked: it means "no opinion", which is nil here, and the fusion
    /// leaves such a chunk out of the embedding's ordering entirely.
    public func similarity(_ lhs: String, _ rhs: String) -> Double? {
        guard let embedding = resolve() else { return nil }
        let left = Self.prepared(lhs)
        let right = Self.prepared(rhs)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        let distance = embedding.distance(between: left, and: right, distanceType: .cosine)
        guard distance.isFinite, distance < Double.greatestFiniteMagnitude / 2 else {
            return nil
        }
        return 1.0 - distance
    }

    /// The embedding, loaded once. Nil forever on a device that does not have it.
    private func resolve() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        return embedding
    }

    /// What is actually embedded: the chunk's prose, on one line, and not too much of
    /// it.
    ///
    /// A sentence embedding over two thousand characters of markdown — headings, task
    /// boxes, wiki-link brackets — is dominated by the punctuation. Newlines collapse to
    /// spaces and the text is capped, because the job here is a second opinion on
    /// relevance, not a faithful encoding of the note.
    public nonisolated static let maxEmbeddedCharacters = 600

    nonisolated static func prepared(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flattened.prefix(maxEmbeddedCharacters))
    }
}
