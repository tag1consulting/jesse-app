import SwiftUI

// The one sentence the composer says while the Studio cannot be reached, and why it is a
// view of its own rather than four modifiers inline in `MacThreadDetailView.composer`:
// this caption sits in WINDOW LEVEL content (the composer is the `VStack` sibling of the
// transcript's `ScrollView`, so nothing between it and the window absorbs its height), and
// window level content is measured at a near zero width when AppKit asks the SwiftUI
// content for the window's MINIMUM size. Anything unbounded in that measurement becomes a
// minimum the window cannot be made smaller than. Extracted so that minimum can be
// measured on its own in a test (`MacComposerNoticeLayoutTests`).
//
// WHICH IS WHY THERE IS NO `fixedSize(horizontal: false, vertical: true)` HERE. It used to
// carry one, the ordinary way to stop a caption being clipped to one line, and on the phone
// it is harmless: iOS never asks a view how short it can be at a one point width. AppKit
// does, and a vertically fixed `Text` must answer with its FULLY WRAPPED height for the
// width it is given — roughly one character per line at that width, 1015 pt for this
// sentence. That became the window's minimum content height, so the window could not be
// made shorter than the screen and the composer sat below its bottom edge. A line limit
// bounds the answer instead, and `help` keeps the whole sentence reachable on the rare
// window narrow enough to truncate it.
struct MacCaptureOfferNotice: View {
    /// Said in one place: the caption, the tooltip and the test all read this.
    static let sentence =
        "The Studio can't be reached. Capture to Inbox writes this straight into the vault on this Mac."

    var body: some View {
        Label(Self.sentence, systemImage: "tray.and.arrow.down")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Self.sentence)
    }
}
