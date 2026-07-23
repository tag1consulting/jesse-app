import XCTest
import JesseNetworking
@testable import Jesse_Mac

// Part A: the macOS provenance chip. The Mac ingests a delivered reply the same way iOS
// does — it stores the badge-stripped body plus the compact provenance JSON on the turn, so
// a native chip renders under the reply and survives a reload. `MacCoordinator.turnFields`
// is the pure transform that seam runs; these tests pin its contract (the coordinator's
// `finalize` just applies it to a new `Turn`).

@MainActor
final class MacProvenanceTests: XCTestCase {
    private func flags(citationsUnverified: Bool = false) -> JesseProvenanceFlags {
        JesseProvenanceFlags(hostedVerify: false, verifyQueued: false,
                             citationsUnverified: citationsUnverified)
    }

    func testReplyWithProvenanceStripsBadgeAndCarriesModelAndCost() {
        // A non-Opus hosted reply: the bridge appended a trailing "\n\n<badge>". The Mac
        // must store the clean body and the provenance so the chip shows model + cost.
        let prov = JesseProvenance(route: "hosted", model: "glm-5.2", costUsd: 0.0021,
                                   badge: "[glm-5.2 · $0.0021]", flags: flags())
        let body = "Your protein goal is 180 g."
        let reply = JesseReply(text: body + "\n\n" + prov.badge, sessionId: "s1", provenance: prov)

        let fields = MacCoordinator.turnFields(from: reply)
        XCTAssertEqual(fields.text, body, "the trailing text badge is stripped from the stored body")

        let chip = JesseProvenance.from(json: fields.provenanceJSON)
        XCTAssertEqual(chip?.model, "glm-5.2")
        XCTAssertEqual(chip?.chipTitle, "glm-5.2", "the hosted chip shows the active model")
        XCTAssertEqual(chip?.costUsd ?? -1, 0.0021, accuracy: 1e-9)
        XCTAssertEqual(chip?.costLabel, "$0.0021")
    }

    func testOpusReplyShowsAnOpusChip() {
        let prov = JesseProvenance(route: "hosted", model: "opus", costUsd: 0.0500,
                                   badge: "[opus · $0.0500]", flags: flags())
        let body = "Sure — here's the summary."
        let reply = JesseReply(text: body + "\n\n" + prov.badge, sessionId: "s1", provenance: prov)

        let fields = MacCoordinator.turnFields(from: reply)
        XCTAssertEqual(fields.text, body)
        let chip = JesseProvenance.from(json: fields.provenanceJSON)
        XCTAssertEqual(chip?.chipTitle, "opus")
        XCTAssertEqual(chip?.costLabel, "$0.0500")
    }

    func testReplyWithoutProvenanceIsVerbatimWithNoChip() {
        // An older bridge / badges-off turn: no structured provenance, so the text is shown
        // exactly as delivered and no chip data is stored.
        let raw = "A plain answer with no badge."
        let reply = JesseReply(text: raw, sessionId: "s1", provenance: nil)

        let fields = MacCoordinator.turnFields(from: reply)
        XCTAssertEqual(fields.text, raw, "no provenance → text shown verbatim")
        XCTAssertNil(fields.provenanceJSON, "no provenance → no chip")
        XCTAssertNil(JesseProvenance.from(json: fields.provenanceJSON))
    }

    func testEmptyTerminalResponseFallsBackToStreamedBodyKeepingProvenance() {
        // A `done` frame can carry an empty final `response` while the live stream already
        // accumulated the (badge-free) body. The Mac keeps that body and still attaches the
        // chip, so the stream path and the poll path store identical provenance.
        let prov = JesseProvenance(route: "hosted", model: "glm-5.2", costUsd: 0.0,
                                   badge: "[glm-5.2 · $0.0000]", flags: flags())
        let reply = JesseReply(text: "", sessionId: "s1", provenance: prov)

        let fields = MacCoordinator.turnFields(from: reply, streamedText: "streamed answer body")
        XCTAssertEqual(fields.text, "streamed answer body")
        XCTAssertEqual(JesseProvenance.from(json: fields.provenanceJSON)?.model, "glm-5.2")
    }
}
