import Foundation

// GFM PIPE TABLES, IN ONE PLACE.
//
// These four declarations were `private` inside `Jesse/Jesse/MarkdownText.swift`, where
// they had been since the reply renderer learned to draw a table. They MOVED here, they
// were not copied, and the reason is the vault reader: a note is markdown too, hundreds of
// this vault's notes have tables in them, and the reader could not reach into the iOS app
// target to borrow the rules. The alternative was a second implementation of "what is a
// delimiter row", which is how two renderers start disagreeing about the same file.
//
// The iOS reply renderer still assembles its OWN table block (its ragged-row handling is
// its own and is asserted by its own tests); what it no longer owns is the four primitives
// below.
//
// Pure Foundation. No SwiftUI, no UIKit, nothing platform-shaped: this target is the
// bottom of the package and is meant to stay reachable from anywhere.

/// Per-column horizontal alignment for a GFM pipe table.
public enum TableAlignment: Equatable, Sendable {
    case leading, center, trailing
}

/// True if `line` is a GFM table delimiter row: at least one cell, every cell
/// made only of `-`, `:`, and spaces, and the row contains at least one `-`.
public func isTableDelimiterRow(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|"), trimmed.contains("-") else { return false }
    let cells = splitTableRow(trimmed)
    guard !cells.isEmpty else { return false }
    for cell in cells {
        let stripped = cell.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty,
              stripped.allSatisfy({ $0 == "-" || $0 == ":" }) else {
            return false
        }
    }
    return true
}

/// Per-column alignment from a delimiter row: `:---`=leading, `:--:`=center,
/// `---:`=trailing, plain=leading.
public func parseTableAlignments(_ line: String) -> [TableAlignment] {
    splitTableRow(line.trimmingCharacters(in: .whitespaces)).map { cell in
        let c = cell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        switch (left, right) {
        case (true, true):  return .center
        case (false, true): return .trailing
        default:            return .leading
        }
    }
}

/// Split one pipe-table row into trimmed cells: drop one optional leading and
/// trailing `|`, split on `|`, trim each cell. (Escaped `\|` is out of scope.)
public func splitTableRow(_ line: String) -> [String] {
    var s = Substring(line.trimmingCharacters(in: .whitespaces))
    if s.hasPrefix("|") { s = s.dropFirst() }
    if s.hasSuffix("|") { s = s.dropLast() }
    return s.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}
