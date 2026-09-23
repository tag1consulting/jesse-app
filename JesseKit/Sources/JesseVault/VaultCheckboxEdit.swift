import Foundation

// TICKING ONE BOX, AND NOTHING ELSE.
//
// This is the smallest possible edit and it is written to stay that way. It takes the
// note's whole text and gives back the whole text with ONE line changed and every other
// byte — indentation, trailing spaces, the blank line somebody left at the end, the CRLF
// a Windows machine put there — identical.
//
// It works on the ONE CHARACTER inside the brackets. Not "rebuild the line from its
// parts", which is how a tick quietly strips the two spaces somebody used to align a
// note, or turns a `*` bullet into a `-` one because the rewriter had a favourite. Find
// the box, swap the character between the brackets, leave the rest of the string alone.
//
// Pure, and takes the line NUMBER rather than searching for text. Two identical `- [ ]
// call Marco` lines in one note is an ordinary thing for a task list to contain, and a
// function that matched on text would tick whichever one it found first.

public enum VaultCheckboxEdit {

    /// `text` with the box on 1-based `line` set to `checked`, or nil when that line is
    /// not a checkbox line.
    ///
    /// Nil rather than a throw, and nil rather than returning the text unchanged: the
    /// caller needs to tell "I ticked it" from "that is not a task any more", because the
    /// second one is what a note edited elsewhere looks like and it has to reload rather
    /// than report success.
    public static func setting(_ text: String, line: Int, checked: Bool) -> String? {
        guard line >= 1 else { return nil }
        var all = lines(text)
        guard line <= all.count else { return nil }
        guard let edited = setting(line: all[line - 1], checked: checked) else { return nil }
        all[line - 1] = edited
        return all.joined(separator: "\n")
    }

    /// The file's lines, split on the LF SCALAR and keeping every other byte.
    ///
    /// NOT `split(separator: "\n")`, and this is the trap that cost a test: Swift's
    /// `Character` is a grapheme cluster and `"\r\n"` is ONE of them, so a Character-based
    /// split cannot see the newline inside a CRLF break at all. A CRLF note came back as a
    /// single line, and every line number past the first was out of range — a tick on a
    /// Windows-written note would silently have done nothing.
    ///
    /// Each line keeps its own trailing `\r` where there was one, so joining with `"\n"`
    /// reproduces the file byte for byte. Blank lines are kept (they are lines, and
    /// dropping them would renumber everything after the first one).
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        out.append(String(current))
        return out
    }

    /// One line with its box set, or nil when it has no box.
    ///
    /// Note what is NOT rebuilt: the returned string is the original with one character
    /// replaced at one index. A `\t\t- [ ]   do the thing   ` comes back as
    /// `\t\t- [x]   do the thing   `, trailing spaces and all.
    public static func setting(line: String, checked: Bool) -> String? {
        guard let box = box(in: line) else { return nil }
        var out = line
        out.replaceSubrange(box.mark...box.mark, with: checked ? "x" : " ")
        return out
    }

    /// Where the box is on this line, and whether it is currently ticked.
    ///
    /// The grammar, deliberately narrow: any amount of leading whitespace, a list marker
    /// (`-`, `*`, `+`, or `12.` / `12)`), at least one space, `[`, one character, `]`. The
    /// character must be a space, `x` or `X` — `[-]` and `[/]` are the "cancelled" and
    /// "in progress" marks some vaults use, and this function does not understand them
    /// well enough to be allowed to change them.
    public static func box(in line: String) -> (mark: String.Index, checked: Bool)? {
        var index = line.startIndex
        // Indentation.
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        // The list marker.
        if line[index] == "-" || line[index] == "*" || line[index] == "+" {
            index = line.index(after: index)
        } else if line[index].isNumber {
            while index < line.endIndex, line[index].isNumber {
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == "." || line[index] == ")" else {
                return nil
            }
            index = line.index(after: index)
        } else {
            return nil
        }
        // At least one space between the marker and the box, which is what keeps `-[x]`
        // (not a task, just a hyphen) and `*emphasis*` out.
        guard index < line.endIndex, line[index] == " " || line[index] == "\t" else {
            return nil
        }
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "[" else { return nil }
        let mark = line.index(after: index)
        guard mark < line.endIndex else { return nil }
        let close = line.index(after: mark)
        guard close < line.endIndex, line[close] == "]" else { return nil }
        switch line[mark] {
        case " ":      return (mark, false)
        case "x", "X": return (mark, true)
        default:       return nil
        }
    }

    /// Whether 1-based `line` of `text` is a checkbox line, and its state. Nil when it is
    /// not one — which is how the retry after a conflict decides whether the tick still
    /// makes sense against the file that is there now.
    public static func state(of text: String, line: Int) -> Bool? {
        guard line >= 1 else { return nil }
        let all = lines(text)
        guard line <= all.count else { return nil }
        return box(in: all[line - 1])?.checked
    }
}

/// The one note this app reads but never writes.
///
/// `Today.md` at the vault ROOT is the bridge's output file: the bridge rewrites it whole,
/// and the ids the Today tab's own ticks carry are minted there. A tick written into it
/// from here would be overwritten by the next rewrite at best, and at worst would race one
/// — so the reader shows its boxes as glyphs and says where the real control is.
///
/// A pure function on the path rather than a check inside the writer, so the rule is one
/// line to assert and the reader, the editor and the writer all ask the same question. All
/// three do ask: a caption alone would be a convention, and this is a guarantee.
public enum VaultWriteExemption {

    public static let todayPath = "Today.md"

    /// True when this path is the bridge's day file.
    ///
    /// The ROOT one only. A note called `Today.md` inside `Projects/` is somebody's own
    /// note and is editable like any other; matching on the basename would have made a
    /// folder name enough to silently lose the ability to tick a box.
    public static func isReadOnly(path: String) -> Bool {
        normalised(path) == todayPath
    }

    /// The caption the reader puts at the top of an exempt note. Nil for every other note:
    /// a banner that appears on all of them is a banner nobody reads.
    public static func caption(path: String) -> String? {
        guard isReadOnly(path: path) else { return nil }
        return "Tick items on the Today tab; this file is rewritten by the bridge."
    }

    /// A path as the comparison wants it: no leading `./` or `/`, back slashes forward.
    /// The reader is handed paths from the index, from a wiki link and from a search hit,
    /// and `./Today.md` being editable because of two characters is not a distinction
    /// anybody meant to draw.
    static func normalised(_ path: String) -> String {
        var out = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while out.hasPrefix("./") { out.removeFirst(2) }
        while out.hasPrefix("/") { out.removeFirst() }
        return out
    }
}
