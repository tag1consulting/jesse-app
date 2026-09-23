import Foundation
import SwiftUI

// THE THREE SMALL DECISIONS THE READER MAKES THAT ARE NOT ABOUT MARKDOWN: what a callout
// looks like, whether the reader is showing the file or the note, and how big a table is
// allowed to get before it stops being drawn all at once.
//
// They are here, pure and separately assertable, rather than inside the view, for the
// reason everything else in this target is: a decision taken inside a `body` is a decision
// nobody can test and everybody has to re-derive by looking at a screenshot.

/// What a callout of a given type looks like.
///
/// The TINT is an enum rather than a `Color` so the mapping can be asserted without a
/// rendering environment; the view turns it into a colour and nothing else does.
public struct VaultCalloutStyle: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case blue, green, orange, red, purple, gray
    }

    public let symbol: String
    public let tint: Tint

    public init(symbol: String, tint: Tint) {
        self.symbol = symbol
        self.tint = tint
    }

    /// Obsidian's own callout vocabulary, and the ONE rule that matters for the rest:
    /// an unrecognised type gets the note style rather than nothing. A vault is somebody's
    /// personal notation and it grows types nobody wrote down; a callout that vanished
    /// because its type was unfamiliar would be content lost to a spelling.
    public static func style(for type: String) -> VaultCalloutStyle {
        switch type.lowercased() {
        case "note":                  return .init(symbol: "pencil", tint: .blue)
        case "info":                  return .init(symbol: "info.circle", tint: .blue)
        case "abstract", "summary":   return .init(symbol: "text.alignleft", tint: .blue)
        case "tip":                   return .init(symbol: "flame", tint: .green)
        case "success":               return .init(symbol: "checkmark.circle", tint: .green)
        case "question":              return .init(symbol: "questionmark.circle", tint: .orange)
        case "todo":                  return .init(symbol: "checklist", tint: .blue)
        case "warning":               return .init(symbol: "exclamationmark.triangle", tint: .orange)
        case "failure":               return .init(symbol: "xmark.circle", tint: .red)
        case "danger", "error":       return .init(symbol: "exclamationmark.octagon", tint: .red)
        case "bug":                   return .init(symbol: "ladybug", tint: .red)
        case "example":               return .init(symbol: "list.bullet", tint: .purple)
        case "quote":                 return .init(symbol: "quote.opening", tint: .gray)
        default:                      return .init(symbol: "pencil", tint: .blue)
        }
    }

    /// Whether `type` is one this vault has a style written down for. Only the diagnostics
    /// and the tests ask; the reader never needs to know, because there is always a style.
    public static func isKnown(_ type: String) -> Bool {
        knownTypes.contains(type.lowercased())
    }

    public static let knownTypes: Set<String> = [
        "note", "info", "tip", "warning", "danger", "error", "bug", "example", "quote",
        "question", "todo", "success", "failure", "abstract", "summary",
    ]

    public var color: Color {
        switch tint {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .red:    return .red
        case .purple: return .purple
        case .gray:   return .gray
        }
    }
}

/// Formatted, or the file as text.
public enum VaultReaderMode: String, Equatable, Sendable, CaseIterable {
    case formatted
    case raw

    public var toggled: VaultReaderMode { self == .formatted ? .raw : .formatted }
    public var showsRaw: Bool { self == .raw }

    public init(showsRaw: Bool) { self = showsRaw ? .raw : .formatted }

    /// What the toolbar button says it will do, which is the OTHER mode — a button
    /// labelled with the state you are already in is a button people press twice.
    public var buttonLabel: String { self == .formatted ? "Raw" : "Formatted" }
    public var buttonSymbol: String {
        self == .formatted ? "chevron.left.forwardslash.chevron.right" : "doc.richtext"
    }
}

/// Whether the reader shows markdown or the file, remembered on this device.
///
/// A preference rather than per-note state: somebody who wants to see the markdown wants
/// to see the markdown, and making them press the button again on the next note is the
/// kind of small rudeness that gets a feature abandoned.
///
/// Not `Sendable`, and not made so with an `@unchecked`, for the reason
/// `TodayViewPreferences` gives: `UserDefaults` is a class the compiler cannot vouch for,
/// and this store is read and written from the reader's MainActor view and nowhere else.
/// Claiming more than that would be a claim nobody needs.
public struct VaultReaderPreferences {
    public static let showsRawKey = "vault.reader.showsRaw"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// FALSE by default, and that is the whole argument of this prompt in one line: the
    /// formatted note is what a person came to read.
    public var showsRaw: Bool {
        get { defaults.bool(forKey: Self.showsRawKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.showsRawKey) }
    }

    public var mode: VaultReaderMode {
        get { VaultReaderMode(showsRaw: showsRaw) }
        nonmutating set { showsRaw = newValue.showsRaw }
    }
}

/// How much of a big table is drawn before the reader asks.
///
/// A `LazyVStack` keeps a long NOTE cheap because a block that is not on screen is not
/// built. A `Grid` does not work that way: it builds every cell it is given, so one
/// 600-row table inside an otherwise lazy note is the whole note's frame budget spent in
/// one block. Sixty rows is about two screens on a phone — enough that most tables never
/// meet this at all — and the rest is one button away.
public enum VaultTableWindow {
    public static let initialRows = 60

    /// The rows to draw, and how many are being held back.
    public static func window(rowCount: Int, expanded: Bool) -> (shown: Int, hidden: Int) {
        guard !expanded, rowCount > initialRows else { return (rowCount, 0) }
        return (initialRows, rowCount - initialRows)
    }
}
