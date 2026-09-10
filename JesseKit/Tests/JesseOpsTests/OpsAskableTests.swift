import XCTest
import SwiftUI
import JesseAsk
@testable import JesseOps

// The GESTURE half, where it can be asserted: the two properties of `.askable` that a
// wrong edit would break silently, and that no amount of reading the view tree reveals.
//
// SwiftUI offers no way to enumerate a `contextMenu`'s items from a test, so neither of
// these inspects a rendered menu. Each pins the VALUE the menu is built from, at the place
// a regression would actually be introduced — which is what makes them fail before a fix
// rather than after one.

final class OpsAskableTests: XCTestCase {

    /// A SCREEN WITH NO ACTION INJECTED SHOWS NO MENU. `AskableModifier` renders its content
    /// untouched when `\.jesseAsk` is nil, so the property that keeps previews, tests and
    /// any not-yet-wired shell inert is that the environment's DEFAULT is nil. An
    /// accidentally non-nil default would put a live menu on every askable view in the app.
    @MainActor
    func testNoAskActionIsInjectedByDefault() {
        XCTAssertNil(EnvironmentValues().jesseAsk)
    }

    /// THE LOG TAIL KEEPS ITS COPY. The deploy log tail is the one view on the Ops screen
    /// with `.textSelection(.enabled)`, and attaching a `contextMenu` takes the system's
    /// press-and-hold selection — and its Copy callout — away. It therefore uses the
    /// `copyText:` spelling, and this pins the text that item carries: the whole tail as
    /// shown, and nil when there is no tail and so no item.
    @MainActor
    func testTheDeployLogTailStillHasSomethingToCopy() throws {
        let withTail = try Self.record(logTail: ["fetching origin", "cargo build --release"])
        let view = DeployProgressView(record: withTail, reading: OpsAskReading())
        XCTAssertEqual(view.logTailCopy, "fetching origin\ncargo build --release")

        let empty = try Self.record(logTail: [])
        XCTAssertNil(DeployProgressView(record: empty, reading: OpsAskReading()).logTailCopy,
                     "no tail, no Copy item")
    }

    private static func record(logTail: [String]) throws
        -> DeployStatusDocument.DeployRecord {
        let tail = logTail.map { "\"\($0)\"" }.joined(separator: ", ")
        let doc = try DeployStatusDocument.decode(Data("""
        {"deploy": {"deploy_id": "d-1", "phase": "build", "ref": "main", "sha": null,
                    "started_ms": 1756600000000, "finished_ms": null, "result": null,
                    "reason": null, "log_tail": [\(tail)]},
         "running": {"version": "0.100.0", "sha": null},
         "origin_main": {"sha": null, "version": null, "ci": "none", "ci_detail": null,
                         "checked_ms": 0}}
        """.utf8))
        return try XCTUnwrap(doc.deploy)
    }
}
