import XCTest
import SwiftUI
import AppKit
@testable import Jesse_Mac

// THE WINDOW'S MINIMUM HEIGHT, measured — the layer the "window taller than the screen"
// defect lives in.
//
// The Mac's main `WindowGroup` sets a default size and no minimum, so AppKit derives the
// window's minimum content size from the SwiftUI content by proposing a near zero width and
// asking how short it can be. `MacThreadDetailView` is a `VStack` of the transcript's
// `ScrollView` and the composer, and a `ScrollView` absorbs its content's height while the
// composer does not — so every point the composer claims as a MINIMUM at that near zero
// width is a point the window can never be made shorter than. A caption that must report its
// fully wrapped height (`fixedSize(horizontal: false, vertical: true)`) wraps to roughly one
// character per line there, and a sentence's worth of that is taller than a screen.
//
// These tests measure that minimum rather than inspecting modifiers, because the modifier is
// not the defect: the unbounded height at a near zero proposed width is.
@MainActor
final class MacComposerNoticeLayoutTests: XCTestCase {

    /// The width AppKit probes the content with when it asks for the minimum size. One point
    /// rather than zero: zero is a degenerate proposal SwiftUI may answer with its ideal.
    private static let probeWidth: CGFloat = 1

    /// A caption's worth of height, generously: four lines of `.caption` (~14 pt each) plus
    /// the composer's divider. Anything at or under this is a notice; the defect measured
    /// four figures.
    private static let aFewLines: CGFloat = 80

    /// The minimum height this view reports for `width`: proposing a height of zero asks
    /// SwiftUI for the shortest it can be, which is exactly what becomes the window's
    /// `contentMinSize`.
    private func minimumHeight(of view: some View, at width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 0))
            .height
    }

    /// The notice on its own. At a full window's width it is one line either way; the
    /// measurement that matters is the narrow one.
    func testTheCaptureOfferNoticeStaysAFewLinesTallAtTheWidthAppKitProbesWith() {
        let narrow = minimumHeight(of: MacCaptureOfferNotice(), at: Self.probeWidth)
        let realistic = minimumHeight(of: MacCaptureOfferNotice(), at: 120)
        XCTAssertGreaterThan(narrow, 0, "measured nothing — the notice did not lay out")
        XCTAssertLessThanOrEqual(
            narrow, Self.aFewLines,
            "the notice needs \(narrow) pt at a \(Self.probeWidth) pt width, which the window "
            + "adopts as a minimum it cannot be shorter than")
        XCTAssertLessThanOrEqual(
            realistic, Self.aFewLines,
            "the notice needs \(realistic) pt at a 120 pt width")
    }

    /// The composer's shape, reduced to the two things that make the defect: a flexible
    /// scrolling region above (which does NOT pass its content's height up) and the notice
    /// below it (which does). This is the measurement the window itself takes.
    func testAComposerShapedStackDoesNotForceAWindowTallerThanAScreen() {
        let composerShaped = VStack(spacing: 0) {
            ScrollView { Text("transcript") }
                .frame(maxHeight: .infinity)
            Divider()
            MacCaptureOfferNotice()
        }
        let minimum = minimumHeight(of: composerShaped, at: Self.probeWidth)
        XCTAssertGreaterThan(minimum, 0, "measured nothing — the stack did not lay out")
        XCTAssertLessThanOrEqual(
            minimum, Self.aFewLines,
            "a window built on this content could not be made shorter than \(minimum) pt")
    }

    /// The OTHER control the offer adds to the composer, for the same reason: it is window
    /// level content too. `.fixedSize()` there fixes a single line Label in both axes, which
    /// is bounded — this pins that, so a longer label or a second line cannot quietly turn
    /// the button row into the same defect.
    func testTheComposerRowBesideTheNoticeStaysOneLineTall() {
        let row = HStack(alignment: .bottom, spacing: 10) {
            Label("Capture to Inbox", systemImage: "tray.and.arrow.down")
                .fixedSize()
            Spacer(minLength: 0)
        }
        let minimum = minimumHeight(of: row, at: Self.probeWidth)
        XCTAssertGreaterThan(minimum, 0, "measured nothing — the row did not lay out")
        XCTAssertLessThanOrEqual(minimum, Self.aFewLines,
                                 "the composer's control row needs \(minimum) pt at a "
                                 + "\(Self.probeWidth) pt width")
    }
}
