import XCTest
@testable import Jesse

/// The first-run pairing gate: which empty state the thread list shows when there
/// are no conversations yet. An unpaired user must see the "Pair with your Jesse
/// bridge" CTA (their first send would otherwise just error), a paired one the
/// ordinary "start a conversation" prompt. The decision is pure so it's pinned
/// here without standing up the view.
final class ThreadListEmptyStateTests: XCTestCase {

    func testPairedConfigShowsOrdinaryEmptyState() {
        let cfg = JesseConfig(host: "studio", port: 8765, token: "secret")
        XCTAssertTrue(cfg.isConfigured)
        XCTAssertEqual(threadListEmptyState(for: cfg), .noConversations)
    }

    func testFullyUnconfiguredShowsPairingCTA() {
        let cfg = JesseConfig(host: "", port: 8765, token: "")
        XCTAssertEqual(threadListEmptyState(for: cfg), .pairBridge)
    }

    func testHostWithoutTokenShowsPairingCTA() {
        // Half-paired (host but no bearer token) still can't send — treat as unpaired.
        let cfg = JesseConfig(host: "studio", port: 8765, token: "")
        XCTAssertFalse(cfg.isConfigured)
        XCTAssertEqual(threadListEmptyState(for: cfg), .pairBridge)
    }

    func testTokenWithoutHostShowsPairingCTA() {
        let cfg = JesseConfig(host: "", port: 8765, token: "secret")
        XCTAssertFalse(cfg.isConfigured)
        XCTAssertEqual(threadListEmptyState(for: cfg), .pairBridge)
    }
}
