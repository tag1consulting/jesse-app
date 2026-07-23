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

    func testModelsPayloadDecodesHealthFieldsAndReasons() throws {
        // The health-checked registry (Part B): rows carry configured / healthy / available
        // plus optional last_checked_ms / latency_ms, and the app derives the disabled reason.
        let json = """
        {
          "active": "opus",
          "models": [
            { "id": "opus", "label": "Claude Opus", "kind": "ambient", "configured": true,
              "healthy": true, "available": true, "writes_allowed": true },
            { "id": "fireworks", "label": "Fireworks", "kind": "hosted", "configured": true,
              "healthy": true, "available": true, "writes_allowed": false,
              "last_checked_ms": 1700000000000, "latency_ms": 42 },
            { "id": "glm-5.2", "label": "GLM 5.2", "kind": "hosted", "configured": true,
              "healthy": false, "available": false, "writes_allowed": false,
              "last_checked_ms": 1700000000000, "latency_ms": 3000 },
            { "id": "kimi-k3", "label": "Kimi K3", "kind": "hosted", "configured": false,
              "healthy": false, "available": false, "writes_allowed": false }
          ]
        }
        """
        let state = try JSONDecoder().decode(ModelSwitchState.self, from: Data(json.utf8))

        let fw = try XCTUnwrap(state.models.first { $0.id == "fireworks" })
        XCTAssertTrue(fw.configured && fw.healthy && fw.available)
        XCTAssertNil(fw.unavailableReason, "a configured + healthy model is selectable")
        XCTAssertEqual(fw.latencyMs, 42)
        XCTAssertEqual(fw.lastCheckedMs, 1_700_000_000_000)

        // Configured but the last probe failed → unreachable.
        let glm = try XCTUnwrap(state.models.first { $0.id == "glm-5.2" })
        XCTAssertTrue(glm.configured)
        XCTAssertFalse(glm.healthy)
        XCTAssertFalse(glm.available)
        XCTAssertEqual(glm.unavailableReason, "unreachable")

        // No token/triple armed → not configured.
        let kimi = try XCTUnwrap(state.models.first { $0.id == "kimi-k3" })
        XCTAssertFalse(kimi.configured)
        XCTAssertEqual(kimi.unavailableReason, "not configured")

        // Ambient opus: available with no probe timestamps.
        let opus = try XCTUnwrap(state.models.first { $0.id == "opus" })
        XCTAssertNil(opus.unavailableReason)
        XCTAssertNil(opus.lastCheckedMs)
    }

    func testOlderBridgeWithoutHealthFieldsDefaultsToAvailable() throws {
        // A pre-health bridge omits configured/healthy/last_checked_ms/latency_ms. The app must
        // still decode, defaulting configured/healthy to `available` (the old configured⇒available
        // model), so nothing regresses against an older bridge.
        let json = """
        {
          "active": "opus",
          "models": [
            { "id": "opus", "label": "Claude Opus", "kind": "ambient", "available": true, "writes_allowed": true },
            { "id": "kimi-k3", "label": "Kimi K3", "kind": "hosted", "available": false, "writes_allowed": false }
          ]
        }
        """
        let state = try JSONDecoder().decode(ModelSwitchState.self, from: Data(json.utf8))
        let opus = try XCTUnwrap(state.models.first { $0.id == "opus" })
        XCTAssertTrue(opus.configured && opus.healthy, "available ⇒ configured + healthy on an older bridge")
        XCTAssertNil(opus.unavailableReason)
        let kimi = try XCTUnwrap(state.models.first { $0.id == "kimi-k3" })
        XCTAssertFalse(kimi.configured, "an older bridge's unavailable model reads as not configured")
        XCTAssertEqual(kimi.unavailableReason, "not configured")
        XCTAssertNil(kimi.latencyMs)
    }

    func testPerTurnModelFieldEncodesWhenSetAndOmitsWhenBlank() throws {
        // The per-turn selection rides the `model` key. A non-blank value encodes it; a nil
        // or blank value omits the key entirely (the bridge then uses its stored default,
        // byte-for-byte today's behavior for an older client).
        func encodedKeys(model: String?) throws -> [String: Any] {
            let req = JesseBridgeClient.makeRequest(
                mode: .ask, text: "hi", sessionId: nil, voice: false,
                instructions: nil, floorOverride: nil, attachments: [], model: model)
            let data = try JesseBridgeClient.encodeBody(req)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try encodedKeys(model: "glm-5.2")["model"] as? String, "glm-5.2")
        XCTAssertNil(try encodedKeys(model: nil)["model"], "nil model omits the key")
        XCTAssertNil(try encodedKeys(model: "  ")["model"], "blank model omits the key")
    }

    func testResolvedModelPrefersThreadThenDeviceThenOpus() throws {
        let json = """
        {
          "active": "opus",
          "models": [
            { "id": "opus", "label": "Claude Opus", "kind": "ambient", "available": true, "writes_allowed": true },
            { "id": "glm-5.2", "label": "GLM 5.2", "kind": "hosted", "available": true, "writes_allowed": false },
            { "id": "down", "label": "Down", "kind": "hosted", "configured": true, "healthy": false,
              "available": false, "writes_allowed": false }
          ]
        }
        """
        let state = try JSONDecoder().decode(ModelSwitchState.self, from: Data(json.utf8))
        // The thread's own selection wins when it is available.
        XCTAssertEqual(state.resolvedModel(threadModelID: "glm-5.2", deviceDefaultID: "opus")?.id, "glm-5.2")
        // No thread selection → the device default.
        XCTAssertEqual(state.resolvedModel(threadModelID: nil, deviceDefaultID: "glm-5.2")?.id, "glm-5.2")
        // An unavailable stored id is skipped → fall through to opus.
        XCTAssertEqual(state.resolvedModel(threadModelID: "down", deviceDefaultID: nil)?.id, "opus")
        // Nothing stored → the ambient default.
        XCTAssertEqual(state.resolvedModel(threadModelID: nil, deviceDefaultID: nil)?.id, "opus")
        // Selectable excludes the unhealthy one; menu labels explain the disabled reason.
        XCTAssertEqual(Set(state.selectable.map(\.id)), ["opus", "glm-5.2"])
        XCTAssertEqual(state.models.first { $0.id == "down" }?.menuRowLabel, "Down — unreachable")
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
