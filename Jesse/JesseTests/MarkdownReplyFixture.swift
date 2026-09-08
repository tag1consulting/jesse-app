import Foundation

/// One reply that exercises every block kind the renderer knows, used by both
/// `MarkdownDocumentTests` (document assembly and copy) and
/// `ReplySelectionTextViewTests` (the real text view's selection and copy).
///
/// Deliberately contains, in one document: a heading; three prose paragraphs, the
/// first of which is itself two source lines; three bullets; three numbered items,
/// one carrying an inline link; a fenced code block with meaningful leading
/// whitespace; a GFM table using all three column alignments; and emoji in prose,
/// in a bullet and in a table cell. The cross-paragraph selection test spans the
/// first three paragraphs, which means it also crosses the bullet list — the exact
/// thing the old per-block layout could not do.
enum MarkdownReplyFixture {
    static let raw = """
    # Weekly summary

    You logged 14 meals this week 🍎 and hit protein on five days.
    The gap was Thursday, when dinner went unlogged.

    Three things stood out:

    - Breakfast was consistent — oats and yoghurt 🥣
    - Lunch drifted later each day
    - Dinner protein was the weak point

    Do these next week:

    1. Log dinner before 21:00
    2. Add a protein source at lunch
    3. Read [the protein note](https://example.com/protein)

    Here is the query I used:

    ```
    SELECT day, SUM(protein_g)
      FROM meals
     GROUP BY day
    ```

    | Day | Protein | Met |
    | --- | ------: | :-: |
    | Mon | 128 g | ✅ |
    | Tue | 96 g | ❌ |

    That is the whole picture.
    """

    /// The whole reply as it must reach the pasteboard: block text only, no
    /// Markdown punctuation, list markers kept as real text, a blank line between
    /// blocks except between items of one list, table cells tab-separated with no
    /// layout tab in front of the first column, and code verbatim.
    static let expectedFullCopy = """
    Weekly summary

    You logged 14 meals this week 🍎 and hit protein on five days.
    The gap was Thursday, when dinner went unlogged.

    Three things stood out:

    •\tBreakfast was consistent — oats and yoghurt 🥣
    •\tLunch drifted later each day
    •\tDinner protein was the weak point

    Do these next week:

    1.\tLog dinner before 21:00
    2.\tAdd a protein source at lunch
    3.\tRead the protein note

    Here is the query I used:

    SELECT day, SUM(protein_g)
      FROM meals
     GROUP BY day

    Day\tProtein\tMet
    Mon\t128 g\t✅
    Tue\t96 g\t❌

    That is the whole picture.
    """

    /// A selection that starts inside the FIRST paragraph (at "14 meals") and ends
    /// inside the THIRD ("Do these next week:", after "Do these"). Crosses a
    /// paragraph boundary, a bullet list and another paragraph boundary.
    static let crossParagraphStart = "14 meals"
    static let crossParagraphEndAnchor = "Do these next week"
    static let crossParagraphEndPrefix = "Do these"

    static let expectedCrossParagraphCopy = """
    14 meals this week 🍎 and hit protein on five days.
    The gap was Thursday, when dinner went unlogged.

    Three things stood out:

    •\tBreakfast was consistent — oats and yoghurt 🥣
    •\tLunch drifted later each day
    •\tDinner protein was the weak point

    Do these
    """

    /// A single word, selected the way a double-tap would select one.
    static let singleWord = "Thursday"
}
