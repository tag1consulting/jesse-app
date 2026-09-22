import Foundation

// HOW MUCH CAN THE ON-DEVICE MODEL ACTUALLY HOLD?
//
// Everything planned on top of an offline vault comes down to a budget: how many
// note snippets can be put in front of the on-device model before it refuses. That
// number is not in any document — Apple publishes a token count for a context
// window, not a character count for THIS device with THIS instruction set and THIS
// prompt shape — so it is measured here, on the device, rather than assumed.
//
// The measurement is deliberately crude and honest: grow a prompt until the session
// throws, then bisect. It reports CHARACTERS, not tokens, because characters are
// what a snippet budget is actually spent in.
//
// This file imports no model framework. The seam below is the whole dependency
// surface, exactly as `QueryExpanding` is for search, so the bisection can be
// asserted against a fake that fails above a known size and the real model is never
// called from a test.

/// One round trip to a language model, as the probe needs it: a prompt in, some
/// text out, a throw when the model will not take it.
public protocol ProbeSessioning: Sendable {
    /// Is the model usable at all right now, and if not, why — as one short line.
    var availability: String { get }
    /// True when `availability` means the model can actually be asked something.
    var isAvailable: Bool { get }
    /// Answer `prompt`. Each call must start from a CLEAN session: a probe that
    /// reused one transcript would measure the transcript, not the window.
    func respond(to prompt: String) async throws -> String
}

/// What the probe found.
public struct ModelProbeReport: Sendable, Equatable {
    /// The availability string, verbatim, whatever it says.
    public let availability: String
    /// The largest prompt, in characters, that the model accepted. Nil when the
    /// model is unavailable or when even the smallest probe failed.
    public let largestPromptCharacters: Int?
    /// Wall clock for one 2,000-character prompt answered in about 20 words, in
    /// seconds. Nil when that call could not be made.
    public let roundTripSeconds: TimeInterval?
    /// What happened, in one line, when a number is missing.
    public let note: String?

    public init(availability: String,
                largestPromptCharacters: Int?,
                roundTripSeconds: TimeInterval?,
                note: String?) {
        self.availability = availability
        self.largestPromptCharacters = largestPromptCharacters
        self.roundTripSeconds = roundTripSeconds
        self.note = note
    }

    /// The diagnostics screen's lines, one fact each.
    public var lines: [String] {
        var out = ["Availability: \(availability)"]
        if let largestPromptCharacters {
            out.append("Largest prompt accepted: \(largestPromptCharacters) characters")
        } else {
            out.append("Largest prompt accepted: not measured")
        }
        if let roundTripSeconds {
            out.append(String(format: "2,000-character round trip: %.2f s", roundTripSeconds))
        } else {
            out.append("2,000-character round trip: not measured")
        }
        if let note { out.append(note) }
        return out
    }
}

/// The measurement itself — pure orchestration over the seam, with no model type
/// anywhere in it.
public struct ModelProbe: Sendable {
    /// Where the doubling starts.
    public static let startCharacters = 1_000
    /// The bisection's resolution. The answer is reported to the nearest 500
    /// characters because a snippet budget is not decided in single characters and
    /// each extra step costs a real round trip on the device.
    public static let resolution = 500
    /// A ceiling so a very large window cannot turn this into an unbounded loop.
    /// Reaching it is reported rather than treated as the answer.
    public static let ceiling = 512_000

    private let session: any ProbeSessioning

    public init(session: any ProbeSessioning) {
        self.session = session
    }

    /// Run the probe. Never throws: an unavailable model is a RESULT, not an error,
    /// because "this device cannot do it" is exactly what the diagnostics screen
    /// exists to show.
    public func run() async -> ModelProbeReport {
        let availability = session.availability
        guard session.isAvailable else {
            return ModelProbeReport(availability: availability,
                                    largestPromptCharacters: nil,
                                    roundTripSeconds: nil,
                                    note: "Model unavailable — nothing was measured and nothing was sent anywhere.")
        }

        var note: String?

        // --- Phase 1: double until it breaks.
        var lastGood: Int?
        var firstBad: Int?
        var size = Self.startCharacters
        while size <= Self.ceiling {
            if await accepts(size) {
                lastGood = size
                size *= 2
            } else {
                firstBad = size
                break
            }
        }
        if firstBad == nil, lastGood != nil {
            note = "Every prompt up to the \(Self.ceiling)-character ceiling was accepted; the real limit is higher."
        }

        // --- Phase 2: bisect between the largest accepted and the smallest refused.
        if let low = lastGood, let high = firstBad {
            var lo = low, hi = high
            while hi - lo > Self.resolution {
                let mid = Self.midpoint(lo: lo, hi: hi)
                if mid <= lo || mid >= hi { break }
                if await accepts(mid) { lo = mid } else { hi = mid }
            }
            lastGood = lo
        }
        if lastGood == nil {
            note = "Even a \(Self.startCharacters)-character prompt was refused."
        }

        // --- Phase 3: one timed round trip at a realistic size.
        var roundTrip: TimeInterval?
        let started = Date()
        do {
            _ = try await session.respond(to: Self.timingPrompt())
            roundTrip = Date().timeIntervalSince(started)
        } catch {
            note = (note.map { $0 + " " } ?? "") + "The timed round trip failed: \(error.localizedDescription)"
        }

        return ModelProbeReport(availability: availability,
                                largestPromptCharacters: lastGood,
                                roundTripSeconds: roundTrip,
                                note: note)
    }

    private func accepts(_ characters: Int) async -> Bool {
        do {
            _ = try await session.respond(to: Self.fillerPrompt(characters: characters))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Pure helpers, asserted directly

    /// The bisection midpoint, snapped DOWN to the resolution grid so the search
    /// terminates on a whole number of 500-character steps instead of converging on
    /// an arbitrary one.
    public static func midpoint(lo: Int, hi: Int) -> Int {
        let raw = lo + (hi - lo) / 2
        return (raw / resolution) * resolution
    }

    /// `characters` characters of plain English. Plain English rather than repeated
    /// filler because a tokenizer packs `aaaa…` very differently from prose, and the
    /// number wanted here is the one prose will actually get.
    public static func fillerPrompt(characters: Int) -> String {
        let question = "Reply with the single word OK. Ignore the notes that follow.\n\n"
        let needed = max(0, characters - question.count)
        return question + filler(characters: needed)
    }

    /// The fixed 2,000-character prompt whose round trip is timed.
    public static func timingPrompt() -> String {
        let instruction = "Summarise the notes below in about twenty words.\n\n"
        return instruction + filler(characters: max(0, 2_000 - instruction.count))
    }

    /// Plain-English filler of an exact character length.
    public static func filler(characters: Int) -> String {
        guard characters > 0 else { return "" }
        let sentence = "The kiln was rebuilt in the spring and the first firing went better than anyone expected. "
        var out = ""
        out.reserveCapacity(characters)
        while out.count < characters {
            out += sentence
        }
        return String(out.prefix(characters))
    }
}
