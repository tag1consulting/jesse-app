import Foundation

// The coach notes carry a deliberately tiny HTML subset — only `<strong>` for
// emphasis, plus a handful of typographic entities (`&mdash; &ndash; &rsquo;
// &amp;` and a few friends). This turns that into an `AttributedString` for
// display: `<strong>` spans render bold, known entities decode to their glyph,
// and ANY other tag is stripped (never shown as literal markup). Pure and
// Foundation-only; the tokenizer is exposed as `segments` so the rules are
// unit-testable without inspecting AttributedString runs.

enum CoachHTML {
    /// One run of text with its emphasis, the tokenizer's output.
    struct Segment: Equatable { var text: String; var bold: Bool }

    /// Known HTML entities → their glyph. Anything not listed is passed through
    /// verbatim (including the leading `&`), so unknown markup never crashes or
    /// silently drops text.
    private static let entities: [String: String] = [
        "mdash": "\u{2014}", "ndash": "\u{2013}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "hellip": "\u{2026}", "nbsp": "\u{00A0}",
    ]

    /// Tokenize the limited HTML into bold/plain runs. `<strong>`/`</strong>`
    /// toggle emphasis; every other `<…>` tag is dropped; entities decode.
    /// Adjacent runs of the same emphasis are coalesced.
    static func segments(_ html: String) -> [Segment] {
        var out: [Segment] = []
        var current = ""
        var bold = false

        func flush() {
            guard !current.isEmpty else { return }
            if var last = out.last, last.bold == bold {
                last.text += current
                out[out.count - 1] = last
            } else {
                out.append(Segment(text: current, bold: bold))
            }
            current = ""
        }

        let chars = Array(html)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "<" {
                // Read to the closing '>'. An unterminated '<' is treated literally.
                guard let close = nextIndex(of: ">", in: chars, from: i + 1) else {
                    current.append(ch); i += 1; continue
                }
                let tag = String(chars[(i + 1)..<close])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if tag == "strong" || tag == "b" {
                    flush(); bold = true
                } else if tag == "/strong" || tag == "/b" {
                    flush(); bold = false
                }
                // Any other tag is simply stripped.
                i = close + 1
            } else if ch == "&" {
                // Read to ';' within a short window; decode if known, else literal.
                if let semi = nextIndex(of: ";", in: chars, from: i + 1),
                   semi - i <= 10 {
                    let name = String(chars[(i + 1)..<semi])
                    if let glyph = entities[name] {
                        current += glyph
                        i = semi + 1
                        continue
                    }
                }
                current.append(ch); i += 1
            } else {
                current.append(ch); i += 1
            }
        }
        flush()
        return out
    }

    /// Render the limited HTML as an `AttributedString` with bold runs.
    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        for seg in segments(html) {
            var run = AttributedString(seg.text)
            if seg.bold { run.inlinePresentationIntent = .stronglyEmphasized }
            result.append(run)
        }
        return result
    }

    /// The plain text with all markup removed and entities decoded — for a
    /// single-line truncated headline where bold can't show.
    static func plainText(_ html: String) -> String {
        segments(html).map(\.text).joined()
    }

    private static func nextIndex(of target: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }
}
