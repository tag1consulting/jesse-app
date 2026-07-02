import os

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
}
