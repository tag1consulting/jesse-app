import XCTest
@testable import JesseNetworking

// The picker's layout (`ModelMenuLayout`) and its selection rules (`ModelMenuAction`), which
// both apps render and neither re-derives. One menu; families are sections, not submenus; a
// family of one has no header; effort is one inline control for the resolved model only, and
// only when that model declares a scale; an unavailable model still renders, disabled, with
// its reason.
final class ModelMenuTests: XCTestCase {

    private func model(_ id: String, family: String? = nil, available: Bool = true,
                       configured: Bool? = nil, healthy: Bool? = nil,
                       effort: ModelEffortScale? = nil, kind: String = "hosted",
                       harness: String? = "claude-code", version: String? = nil) -> ModelInfo {
        ModelInfo(id: id, label: id.capitalized, kind: kind, available: available,
                  writesAllowed: true, configured: configured, healthy: healthy,
                  family: family, harness: harness, version: version, effort: effort)
    }

    private let scale = ModelEffortScale(values: ["low", "high", "max"], defaultValue: "high")

    private func state(_ models: [ModelInfo]) -> ModelSwitchState {
        ModelSwitchState(active: "opus", models: models)
    }

    func testAFamilyOfOneRendersNoSectionHeader() {
        let layout = ModelMenuLayout(
            state: state([model("opus", family: "Claude", kind: "ambient"),
                          model("fable", family: "Claude", kind: "subscription"),
                          model("glm", family: "GLM")]),
            threadModelID: nil, deviceDefaultID: nil, threadEffort: nil)
        XCTAssertEqual(layout.sections.map(\.id), ["Claude", "GLM"], "registry order, grouped")
        XCTAssertEqual(layout.sections[0].header, "Claude", "two models: a header")
        XCTAssertEqual(layout.sections[0].rows.map(\.id), ["opus", "fable"])
        XCTAssertNil(layout.sections[1].header, "a family of one is a plain row, not a level")
        XCTAssertEqual(layout.sections[1].rows.map(\.id), ["glm"])
    }

    func testAModelWithNoDeclaredEffortScaleRendersNoEffortSection() {
        let layout = ModelMenuLayout(
            state: state([model("opus", effort: scale, kind: "ambient"),
                          model("kimi", effort: nil)]),
            threadModelID: "kimi", deviceDefaultID: nil, threadEffort: "max")
        XCTAssertNil(layout.effort, "kimi declares no scale, so there is no effort control")
        XCTAssertEqual(layout.buttonLabel, "Kimi", "and no effort in the label")
    }

    func testAScaleRendersOnePickerWithTheEffortInForceSelected() {
        let layout = ModelMenuLayout(state: state([model("glm", effort: scale)]),
                                     threadModelID: "glm", deviceDefaultID: nil,
                                     threadEffort: "low")
        XCTAssertEqual(layout.effort, .picker(values: ["low", "high", "max"], selected: "low"))
        XCTAssertEqual(layout.buttonLabel, "Glm · low", "a non-default effort joins the label")

        let atDefault = ModelMenuLayout(state: state([model("glm", effort: scale)]),
                                        threadModelID: "glm", deviceDefaultID: nil,
                                        threadEffort: nil)
        XCTAssertEqual(atDefault.effort, .picker(values: ["low", "high", "max"], selected: "high"))
        XCTAssertEqual(atDefault.buttonLabel, "Glm", "the default adds nothing to the toolbar")
    }

    func testAnOnOffScaleRendersAToggleAndNotAPicker() {
        let onOff = ModelEffortScale(kind: "toggle", values: ["off", "on"], defaultValue: "on")
        let layout = ModelMenuLayout(state: state([model("thinker", effort: onOff)]),
                                     threadModelID: "thinker", deviceDefaultID: nil,
                                     threadEffort: "off")
        XCTAssertEqual(layout.effort, .toggle(off: "off", on: "on", isOn: false))
        guard case .toggle = layout.effort else { return XCTFail("a toggle, not a picker") }
    }

    func testAnUnhealthyModelStillRendersDisabledWithItsReason() {
        let layout = ModelMenuLayout(
            state: state([model("opus", kind: "ambient"),
                          model("glm", available: false, configured: true, healthy: false),
                          model("qwen", available: false, configured: false, healthy: false)]),
            threadModelID: nil, deviceDefaultID: nil, threadEffort: nil)
        let rows = layout.sections.flatMap(\.rows)
        let glm = try? XCTUnwrap(rows.first { $0.id == "glm" })
        XCTAssertEqual(glm?.isEnabled, false, "present and disabled, not hidden")
        XCTAssertEqual(glm?.title, "Glm — unreachable", "an outage must not look like a deletion")
        XCTAssertEqual(rows.first { $0.id == "qwen" }?.title, "Qwen — not configured")
    }

    func testTheResolvedModelCarriesTheCheckmarkAndTheHarnessDetail() {
        let layout = ModelMenuLayout(
            state: state([model("opus", kind: "ambient"),
                          model("glm", harness: "claude-code", version: "5.3")]),
            threadModelID: "glm", deviceDefaultID: nil, threadEffort: nil)
        let rows = layout.sections.flatMap(\.rows)
        XCTAssertEqual(rows.filter(\.isSelected).map(\.id), ["glm"], "exactly one checkmark")
        XCTAssertEqual(rows.first { $0.id == "glm" }?.subtitle, "claude-code · 5.3")
        XCTAssertNil(rows.first { $0.id == "opus" }?.subtitle, "detail on the selected row only")
    }

    func testTheMenuRendersTruthfullyBeforeTheModelListLoads() {
        let layout = ModelMenuLayout(state: nil, threadModelID: "glm", deviceDefaultID: nil,
                                     threadEffort: "low")
        XCTAssertTrue(layout.sections.isEmpty, "nothing to list yet")
        XCTAssertNil(layout.effort, "no effort control without a declaration to read")
        XCTAssertEqual(layout.buttonLabel, "glm", "the next turn's model, never blank")
        XCTAssertEqual(ModelMenuLayout(state: nil, threadModelID: nil, deviceDefaultID: nil,
                                       threadEffort: nil).buttonLabel, "opus")
    }

    func testPickingAnotherModelClearsTheEffortAndPickingAnEffortPinsItsModel() {
        let glm = model("glm", effort: scale)
        let qwen = model("qwen", effort: scale)
        XCTAssertEqual(ModelMenuAction.pick(qwen, currentModelID: "glm", currentEffort: "max").effort,
                       nil, "an effort belongs to the model it was chosen on")
        XCTAssertEqual(ModelMenuAction.pick(glm, currentModelID: "glm", currentEffort: "max").effort,
                       "max", "re-picking the same model keeps it")
        let pinned = ModelMenuAction.pickEffort("low", on: glm)
        XCTAssertEqual(pinned.modelID, "glm")
        XCTAssertEqual(pinned.effort, "low")
        XCTAssertNil(ModelMenuAction.pickEffort("high", on: glm).effort,
                     "the default is stored as nil, so a default turn is unchanged")
    }

    func testAnEffortIsSentOnlyWithTheThreadsOwnModelAndOnlyWhileDeclared() {
        XCTAssertNil(ModelMenuAction.effortToSend(threadModelID: nil, threadEffort: "low"),
                     "a thread on the device default has no model of its own to send it with")
        XCTAssertEqual(ModelMenuAction.effortToSend(threadModelID: "glm", threadEffort: "low"), "low")
        // A provider change: the model stops declaring `low`, and the stored value is dropped.
        let narrowed = ModelEffortScale(values: ["high", "max"], defaultValue: "high")
        XCTAssertNil(ModelMenuAction.sanitizedEffort(
            state: state([model("glm", effort: narrowed)]),
            threadModelID: "glm", deviceDefaultID: nil, threadEffort: "low"))
    }

    func testThePerTurnEffortFieldEncodesWhenSetAndOmitsWhenBlank() throws {
        func body(_ effort: String?) throws -> [String: Any] {
            let request = JesseBridgeClient.makeRequest(
                mode: .ask, text: "hi", sessionId: nil, conversationId: "c", voice: false,
                instructions: nil, floorOverride: nil, attachments: [], requestId: "r",
                model: "glm", effort: effort)
            return try XCTUnwrap(try JSONSerialization.jsonObject(
                with: JesseBridgeClient.encodeBody(request)) as? [String: Any])
        }
        XCTAssertEqual(try body("low")["effort"] as? String, "low")
        XCTAssertNil(try body(nil)["effort"], "nil omits the key: the model's default runs")
        XCTAssertNil(try body("  ")["effort"], "blank omits it too")
        XCTAssertEqual(try body(nil)["model"] as? String, "glm", "and the model is untouched")
    }

    func testTheEffortScaleDecodesFromTheBridgeRow() throws {
        let json = """
        { "id": "glm", "label": "GLM 5.3", "kind": "hosted", "available": true,
          "writes_allowed": true, "family": "GLM", "harness": "claude-code", "version": "5.3",
          "effort": { "kind": "scale", "values": ["low", "high", "max"], "default": "high" } }
        """
        let m = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        XCTAssertEqual(m.family, "GLM")
        XCTAssertEqual(m.detailLine, "claude-code · 5.3")
        XCTAssertEqual(m.effort, ModelEffortScale(values: ["low", "high", "max"], defaultValue: "high"))
        let bare = try JSONDecoder().decode(ModelInfo.self, from: Data("""
        { "id": "kimi", "label": "Kimi K3", "kind": "hosted", "available": true,
          "writes_allowed": true, "effort": null }
        """.utf8))
        XCTAssertNil(bare.effort, "null is no scale")
        XCTAssertEqual(bare.family, "kimi", "an older bridge: every model is its own family")
    }
}
