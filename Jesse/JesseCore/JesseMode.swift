import Foundation

// The turn mode, shared by every Jesse client (iOS, watch relay, macOS). Extracted
// from `JesseClient.swift` into `JesseCore/` so the SwiftData models (which store a
// `mode` raw value) and the macOS target can reference it without pulling in the
// iOS networking client. The raw values ("ask"/"tell") are the wire contract the
// bridge expects on `POST /jesse`, so they must not change.
enum JesseMode: String, CaseIterable, Identifiable {
    case ask, tell
    var id: String { rawValue }
    var label: String { self == .ask ? "Ask Jesse" : "Tell Jesse" }
}
