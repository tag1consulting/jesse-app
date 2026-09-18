import Foundation
import os

// Body-evaluation instrumentation: one log line per SwiftUI body evaluation, for the one
// question a sampling profiler answers badly — HOW MANY views one database save
// re-renders, and which ones.
//
// It exists because that number is what the unread badge got wrong. A `@Query` on the
// app's ROOT view is refetched on every save that touches its entity, and each refetch
// re-evaluates the root's body, which rebuilds every tab under it. Nothing about that is
// visible in a stack trace: the work is spread across dozens of small body evaluations,
// each of them fast, and the cost is their number. Counting them is the measurement, and
// `App 1.0 (131)` (the per-keystroke draft save) was diagnosed by counting exactly the
// same thing.
//
// OFF UNLESS ASKED. `JESSE_RENDER_PROBE=1` in the environment turns it on; without it
// every call is a bool check and a return, which is why the call sites are unconditional
// and there is no `#if DEBUG` anywhere near them. A UI test sets the variable through
// `XCUIApplication.launchEnvironment` (the same seam `JESSE_UITEST_BRIDGE` uses) and reads
// the lines back out of the simulator's log afterwards.
//
// NOTICE level, not debug: a debug-level message is only captured while something is
// actively streaming the log, so a run whose stream dropped a chunk would silently
// under-count. A notice is persisted and can be read back with `log show` after the run
// has finished, which makes the count reproducible rather than live-only.
public nonisolated struct RenderProbe: Sendable {

    /// Read once, at first use. The variable is set at launch and never changes within a
    /// process, so re-reading the environment per body evaluation would buy nothing.
    private nonisolated static let isEnabled =
        ProcessInfo.processInfo.environment["JESSE_RENDER_PROBE"] == "1"

    private nonisolated static let logger =
        Logger(subsystem: "com.tag1.jesse", category: "render")

    /// Note that `view`'s body is being evaluated. Call it as the FIRST statement of the
    /// body, as `let _ = RenderProbe.body("Name")` inside the `ViewBuilder` block or ahead
    /// of an explicit `return`.
    ///
    /// `StaticString` so the name can only ever be a literal: this is a counter keyed by
    /// view, and a name interpolated per evaluation would both cost something and make the
    /// keys unsummable.
    public nonisolated static func body(_ view: StaticString) {
        guard isEnabled else { return }
        logger.notice("body \(view, privacy: .public)")
    }

    /// Note a named moment, so the body lines either side of it can be attributed to an
    /// action. Used by the measurement's driver, never by the app.
    public nonisolated static func mark(_ label: String) {
        guard isEnabled else { return }
        logger.notice("mark \(label, privacy: .public)")
    }
}
