import XCTest
@testable import JesseNetworking

// The wire contract for the global model switch (bridge 0.27.0): the `GET /jesse/models`
// payload decodes into `ModelSwitchState`/`ModelInfo` under the bridge's snake_case keys,
// the two mutator request bodies encode the bridge's field names, and a hosted reply's
// structured `provenance` carries the active model + per-turn `cost_usd`.
final class ModelSwitchWireTests: XCTestCase {

    func testModelsPayloadDecodes() throws {
        let json = """
        {
          "active": "glm-5.2",
          "models": [
            { "id": "opus", "label": "Claude Opus", "kind": "ambient", "available": true, "writes_allowed": true },
            { "id": "glm-5.2", "label": "GLM 5.2", "kind": "hosted", "available": true, "writes_allowed": false },
            { "id": "kimi-k3", "label": "Kimi K3", "kind": "hosted", "available": false, "writes_allowed": false },
            { "id": "local", "label": "Local", "kind": "local", "available": false, "writes_allowed": false }
          ]
        }
        """
        let state = try JSONDecoder().decode(ModelSwitchState.self, from: Data(json.utf8))
        XCTAssertEqual(state.active, "glm-5.2")
        XCTAssertEqual(state.models.count, 4)

        let opus = try XCTUnwrap(state.models.first { $0.id == "opus" })
        XCTAssertTrue(opus.isDefault)
        XCTAssertTrue(opus.available)
        XCTAssertTrue(opus.writesAllowed)

        let glm = try XCTUnwrap(state.activeModel)
        XCTAssertEqual(glm.id, "glm-5.2")
        XCTAssertEqual(glm.kind, "hosted")
        XCTAssertFalse(glm.isDefault)
        XCTAssertFalse(glm.writesAllowed, "a non-default model is read-only by default")

        let kimi = try XCTUnwrap(state.models.first { $0.id == "kimi-k3" })
        XCTAssertFalse(kimi.available, "an unavailable model shows disabled")
    }

    func testMutatorBodiesEncodeTheBridgeFieldNames() throws {
        let model = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SetModelBody(id: "glm-5.2"))) as? [String: Any]
        XCTAssertEqual(model?["id"] as? String, "glm-5.2")

        let writes = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SetWritesBody(enabled: true))) as? [String: Any]
        XCTAssertEqual(writes?["enabled"] as? Bool, true)
    }

    func testHostedProvenanceCarriesActiveModelAndCost() throws {
        let json = """
        { "route": "hosted", "model": "glm-5.2", "cost_usd": 0.0021, "badge": "[glm-5.2 · $0.0021]",
          "flags": { "hosted_verify": false, "verify_queued": false, "citations_unverified": false } }
        """
        let p = try JSONDecoder().decode(JesseProvenance.self, from: Data(json.utf8))
        XCTAssertEqual(p.model, "glm-5.2")
        XCTAssertEqual(p.costUsd ?? -1, 0.0021, accuracy: 1e-9)
        XCTAssertEqual(p.costLabel, "$0.0021")
        XCTAssertTrue(p.accessibilityText.contains("cost $0.0021"))
    }

    func testLocalProvenanceWithoutCostDecodesAndHasNoCostLabel() throws {
        // A local route omits cost_usd; an older bridge omits it too. Both decode cleanly.
        let json = """
        { "route": "vaultqa-local", "model": "local-oss", "badge": "[local · vault · local-oss]",
          "flags": { "hosted_verify": false, "verify_queued": false, "citations_unverified": false } }
        """
        let p = try JSONDecoder().decode(JesseProvenance.self, from: Data(json.utf8))
        XCTAssertNil(p.costUsd)
        XCTAssertNil(p.costLabel)
    }
}
