import os
import JesseCore

// Centralized logging for the app's diagnostics. These replace the scattered
// `print()` calls that vanished on release builds (print writes to stdout, which
// a released app has no console for) — os.Logger lands in the unified logging
// system and is inspectable in Console.app / `log stream`, retroactively too.
//
// `AppLog` wraps `os.Logger` with plain-`String` methods so call sites don't each
// need `import os` (the `privacy:` string-interpolation overloads live in the os
// module). Every message is logged `.public`: these are our own diagnostic strings
// — the bearer token and other secrets are never passed here — so redacting them to
// `<private>` would defeat the point of having them at all.
// `nonisolated` throughout so diagnostics can be logged from any context — the
// watch relay logs from nonisolated WCSession delegate callbacks. `Logger` is
// Sendable, so `AppLog` is too.
struct AppLog: Sendable {
    let logger: Logger

    nonisolated func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    nonisolated func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    nonisolated func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
}

/// `OSSignposter` wrapped the way `AppLog` wraps `Logger`: plain-`String` methods, so
/// call sites do not each need `import os` for the interpolation overloads. Every
/// message is `.public` for the same reason `AppLog`'s are — these are our own
/// diagnostic strings, and the whole point of them is being readable in Instruments.
///
/// A signpost INTERVAL rather than a log line because the question being asked of it is
/// "how long did this take, by condition" — a duration distribution, which is what
/// Instruments renders from these and what a `notice` cannot give you.
struct FixSignpost: Sendable {
    let signposter: OSSignposter

    /// Open an interval. The returned state must be handed back to `end` exactly once.
    nonisolated func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    nonisolated func end(_ name: StaticString, _ state: OSSignpostIntervalState,
                         _ message: String) {
        signposter.endInterval(name, state, "\(message, privacy: .public)")
    }
}

enum Log {
    private nonisolated static let subsystem = "com.tag1.jesse"

    /// Turn lifecycle: send → consume → finish, and the recoverable/terminal
    /// failure paths. The silent-loss diagnostics live here.
    nonisolated static let run = AppLog(logger: Logger(subsystem: subsystem, category: "run"))
    /// Spoken-reply audio-session configuration and routing failures.
    nonisolated static let speaker = AppLog(logger: Logger(subsystem: subsystem, category: "speaker"))
    /// Push registration / remote-notification callbacks.
    nonisolated static let push = AppLog(logger: Logger(subsystem: subsystem, category: "push"))
    /// Keychain reads/writes for the bridge config (host/port/token).
    nonisolated static let keychain = AppLog(logger: Logger(subsystem: subsystem, category: "keychain"))
    /// On-device query-expansion (Foundation Models) diagnostics — availability and
    /// per-call failures, which are swallowed to `[]` and never surfaced to the UI.
    nonisolated static let search = AppLog(logger: Logger(subsystem: subsystem, category: "search"))
    /// HealthKit authorization / recent-workout query diagnostics. Query failures are
    /// swallowed to an empty result (no block attached) and never surfaced to the UI.
    nonisolated static let health = AppLog(logger: Logger(subsystem: subsystem, category: "health"))
    /// CoreLocation authorization / fix / reverse-geocode diagnostics. Failures are
    /// swallowed to an empty reading (no block attached) and never surfaced to the UI.
    /// It logs statuses and failures only — never a coordinate or a place name.
    nonisolated static let location = AppLog(logger: Logger(subsystem: subsystem, category: "location"))
    /// Duration signposts around each location fix attempt, so the deadlines in
    /// `LocationFixBudget` can be chosen from a measured distribution rather than
    /// guessed — which is how the 2-second one that broke the channel was arrived at.
    /// Each interval carries elapsed time, achieved accuracy and outcome, and — like
    /// every other line in this category — **no coordinate and no place name**.
    nonisolated static let locationFix = FixSignpost(
        signposter: OSSignposter(subsystem: subsystem, category: "location"))
}
