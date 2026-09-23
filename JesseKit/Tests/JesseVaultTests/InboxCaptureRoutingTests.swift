import XCTest
@testable import JesseVault

// WHETHER THE COMPOSER OFFERS A CAPTURE AT ALL.
//
// Two inputs, no state, so every case is a line. The property worth asserting is the
// DEFAULT: in every combination but one the composer looks exactly as it did before this
// feature existed, which is what makes the change safe to ship to a device that has no
// vault folder.
final class InboxCaptureRoutingTests: XCTestCase {

    func testUnreachableWithAFolderIsTheOnlyOffer() {
        XCTAssertEqual(InboxCaptureRouting.offer(reachability: .unreachable,
                                                 hasVaultFolder: true), .offered)
        XCTAssertTrue(InboxCaptureRouting.offer(reachability: .unreachable,
                                                hasVaultFolder: true).isOffered)
    }

    func testUnreachableWithoutAFolderOffersNothing() {
        XCTAssertEqual(InboxCaptureRouting.offer(reachability: .unreachable,
                                                 hasVaultFolder: false), .hidden)
    }

    func testReachableNeverOffers() {
        for hasFolder in [true, false] {
            XCTAssertEqual(InboxCaptureRouting.offer(reachability: .reachable,
                                                     hasVaultFolder: hasFolder), .hidden)
        }
    }

    /// `.unknown` is a cold launch's pre-probe state. A second send control appearing there
    /// would be offered to someone whose bridge is perfectly fine.
    func testUNKNOWNNeverOffers() {
        for hasFolder in [true, false] {
            XCTAssertEqual(InboxCaptureRouting.offer(reachability: .unknown,
                                                     hasVaultFolder: hasFolder), .hidden)
        }
    }
}
