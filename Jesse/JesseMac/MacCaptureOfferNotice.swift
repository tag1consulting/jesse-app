import SwiftUI

// The one sentence the composer says while the Studio cannot be reached, and why it is a
// view of its own rather than four modifiers inline in `MacThreadDetailView.composer`:
// this caption sits in WINDOW LEVEL content (the composer is the `VStack` sibling of the
// transcript's `ScrollView`, so nothing between it and the window absorbs its height), and
// window level content is measured at a near zero width when AppKit asks the SwiftUI
// content for the window's MINIMUM size. Anything unbounded in that measurement becomes a
// minimum the window cannot be made smaller than. Extracted so that minimum can be
// measured on its own in a test (`MacComposerNoticeLayoutTests`).
struct MacCaptureOfferNotice: View {
    /// Said in one place: the caption, the tooltip and the test all read this.
    static let sentence =
        "The Studio can't be reached. Capture to Inbox writes this straight into the vault on this Mac."

    var body: some View {
        Label(Self.sentence, systemImage: "tray.and.arrow.down")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
