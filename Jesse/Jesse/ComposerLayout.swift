import Foundation

/// Layout floor for the thread composer's text field.
///
/// The input is `TextField(..., axis: .vertical)`. With a `1...` lower bound it
/// could be squeezed to a single, unusable line whenever the transcript, the
/// staged-attachment chips, and the keyboard competed for vertical space. The fix
/// has two named pieces that live here so the floor is a documented invariant a
/// future edit can't quietly drop:
///
/// * `inputMinLines` — the field reserves at least this many lines even when
///   empty (applied as the lower bound of a `.lineLimit` range). A range's lower
///   bound reserves the height *including* the rounded border, so this is the
///   correct floor mechanism for a `.roundedBorder` field — an explicit
///   `.frame(minHeight:)` would leave the small bordered control floating inside a
///   taller frame. The composer is additionally given a higher `.layoutPriority`
///   than the transcript so, under compression, the transcript scrolls/yields and
///   the field keeps this floor.
/// * `inputMaxLines` — the field still grows with content up to this cap, then
///   scrolls internally rather than eating the whole transcript.
enum ComposerLayout {
    /// Minimum usable height of the composer input, in lines. Kept multi-line so
    /// composing stays comfortable with chips staged and the keyboard up.
    static let inputMinLines = 3

    /// Upper bound: the field grows to this many lines, then scrolls internally.
    static let inputMaxLines = 8

    /// The `.lineLimit` range applied to the input — reserves `inputMinLines`,
    /// grows to `inputMaxLines`.
    static var inputLineLimit: ClosedRange<Int> { inputMinLines...inputMaxLines }
}
