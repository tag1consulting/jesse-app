# Strand family tones

The two PNGs here are the output of `StrandBoardRenderTests` in `JesseKit`, which draws
the Strands board's `Tree` lens through the real `StrandRow` and the real `StrandTone`
with SwiftUI's `ImageRenderer` — no simulator, no UI automation. They are checked in so
the pull request that introduced the palette (App 1.0 (171)) can show what it changed, and
so a later edit to the table has something to compare against.

To regenerate them:

    STRAND_BOARD_PNG_DIR=docs/strand-tones \
      swift test --package-path JesseKit --filter StrandBoardRenderTests

The rule the pictures show, and the contract the tests assert, are written at the top of
`JesseKit/Sources/JesseTodayDisplay/TodayProjectPalette.swift`.
