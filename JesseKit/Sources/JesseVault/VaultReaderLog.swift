import Foundation
import OSLog

// THE ONE LINE THAT MAKES THE BUDGET MEASURABLE OFF A DEBUGGER.
//
// "Opening a long note must not get slower" is a claim about a phone in somebody's hand,
// and the phone in somebody's hand is not attached to Instruments. One `Logger` line at
// the moment a note becomes readable is what lets the number be recovered afterwards, from
// Console or from a sysdiagnose, on the device that actually matters.
//
// Nothing here is shown to anybody and nothing here is sent anywhere: it is a local log
// line, and it names a note's PATH, which is already on this device, and never its
// contents.
public enum VaultReaderLog {
    static let logger = Logger(subsystem: "com.tag1.jesse", category: "vault-reader")

    public static func loaded(path: String, blocks: Int, bytes: Int, milliseconds: Double) {
        logger.info("""
            vault-reader loaded path=\(path, privacy: .public) \
            blocks=\(blocks, privacy: .public) lines=\(bytes, privacy: .public) \
            ms=\(String(format: "%.1f", milliseconds), privacy: .public)
            """)
    }
}
