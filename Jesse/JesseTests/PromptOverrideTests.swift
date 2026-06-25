import XCTest
import SwiftData
@testable import Jesse

/// Covers the prompt-customization path: the `POST /jesse` body shape (override
/// included only when it carries content), the `GET /jesse/prompts` decode, the
/// `PromptStore` override decision, and that `RunCoordinator` forwards the
/// resolved override into `send` (including on a voice turn).
final class PromptOverrideTests: XCTestCase {

    // MARK: - requestBody (POST /jesse shape)

    func testRequestBodyIncludesInstructionsWhenCustomized() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: "CUSTOM WRAP",
                                        floorOverride: nil, attachments: [])
        XCTAssertEqual(b["instructions"] as? String, "CUSTOM WRAP")
    }

    func testRequestBodyOmitsInstructionsWhenNil() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: nil,
                                        floorOverride: nil, attachments: [])
        XCTAssertNil(b["instructions"], "an absent override must omit the field")
        // Byte-compat: an ordinary turn carries only mode + text.
        XCTAssertEqual(b["mode"] as? String, "ask")
        XCTAssertEqual(b["text"] as? String, "hi")
        XCTAssertNil(b["voice"])
    }

    func testRequestBodyOmitsBlankInstructions() {
        let b = JesseClient.requestBody(mode: .tell, text: "hi", sessionId: nil,
                                        voice: false, instructions: "   \n\t",
                                        floorOverride: nil, attachments: [])
        XCTAssertNil(b["instructions"], "a blank override means use the default → omit")
    }

    func testRequestBodyVoiceAndOverrideCoexist() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: true, instructions: "VOICE WRAP",
                                        floorOverride: nil, attachments: [])
        XCTAssertEqual(b["voice"] as? Bool, true)
        XCTAssertEqual(b["instructions"] as? String, "VOICE WRAP")
    }

    func testRequestBodyIncludesFloorOverrideWhenSet() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: nil,
                                        floorOverride: "CUSTOM FLOOR", attachments: [])
        XCTAssertEqual(b["floor_override"] as? String, "CUSTOM FLOOR")
    }

    func testRequestBodyOmitsFloorOverrideWhenNilOrBlank() {
        let nilCase = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                              voice: false, instructions: nil,
                                              floorOverride: nil, attachments: [])
        XCTAssertNil(nilCase["floor_override"], "an absent floor override must omit the field")
        let blankCase = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                                voice: false, instructions: nil,
                                                floorOverride: "  \n\t", attachments: [])
        XCTAssertNil(blankCase["floor_override"], "a blank floor override means use the default → omit")
    }

    func testRequestBodyFloorOverrideDoesNotDropInstructions() {
        let b = JesseClient.requestBody(mode: .tell, text: "hi", sessionId: nil,
                                        voice: false, instructions: "WRAP",
                                        floorOverride: "FLOOR", attachments: [])
        XCTAssertEqual(b["instructions"] as? String, "WRAP")
        XCTAssertEqual(b["floor_override"] as? String, "FLOOR")
    }

    // MARK: - decodePrompts (GET /jesse/prompts)

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h:8765/jesse/prompts")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testDecodePromptsValid() throws {
        let json = #"{"ask":"ASK WRAP","tell":"TELL WRAP","ask_floor":"ASK FLOOR","tell_floor":"TELL FLOOR"}"#.data(using: .utf8)!
        let p = try JesseClient.decodePrompts(data: json, resp: http(200))
        XCTAssertEqual(p.ask, "ASK WRAP")
        XCTAssertEqual(p.tell, "TELL WRAP")
        XCTAssertEqual(p.askFloor, "ASK FLOOR")
        XCTAssertEqual(p.tellFloor, "TELL FLOOR")
    }

    func testDecodePromptsNon2xxThrows() {
        let json = "Unauthorized".data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(401)))
    }

    func testDecodePromptsMissingFieldThrows() {
        let json = #"{"ask":"only ask"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(200)))
    }

    func testDecodePromptsMissingFloorThrows() {
        // A bridge too old to expose the floors can't enforce them — fail rather
        // than show none.
        let json = #"{"ask":"ASK WRAP","tell":"TELL WRAP"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(200)))
    }

    // MARK: - PromptStore override decision

    private func clearPromptDefaults() {
        let d = UserDefaults.standard
        for mode in ["ask", "tell"] {
            // Wrapper keys (un-suffixed) plus the floor slot's keys.
            for suffix in ["text", "customized", "default",
                           "floor.text", "floor.customized", "floor.default"] {
                d.removeObject(forKey: "jesse.prompt.\(mode).\(suffix)")
            }
        }
    }

    override func setUp() { super.setUp(); clearPromptDefaults() }
    override func tearDown() { clearPromptDefaults(); super.tearDown() }

    func testOverrideNilWhenUntouched() {
        XCTAssertNil(PromptStore.wrapperOverride(for: .ask))
        XCTAssertNil(PromptStore.wrapperOverride(for: .tell))
    }

    func testOverrideSentWhenCustomizedAndDiffers() {
        PromptStore.save(.ask, .wrapper, text: "MY WRAP", default: "DEFAULT WRAP")
        XCTAssertTrue(PromptStore.customized(.ask, .wrapper))
        XCTAssertEqual(PromptStore.wrapperOverride(for: .ask), "MY WRAP")
    }

    func testOverrideOmittedWhenEqualsDefault() {
        PromptStore.save(.ask, .wrapper, text: "DEFAULT WRAP", default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.ask, .wrapper))
        XCTAssertNil(PromptStore.wrapperOverride(for: .ask))
    }

    func testOverrideOmittedWhenEmpty() {
        PromptStore.save(.tell, .wrapper, text: "", default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.tell, .wrapper))
        XCTAssertNil(PromptStore.wrapperOverride(for: .tell))
    }

    // MARK: - Floor slot (independent of the wrapper slot)

    func testFloorOverrideNilWhenBlankOrEqualsDefault() {
        // Untouched.
        XCTAssertNil(PromptStore.floorOverride(for: .ask))
        // Equal to the recommended default → omit.
        PromptStore.save(.ask, .floor, text: "REC FLOOR", default: "REC FLOOR")
        XCTAssertFalse(PromptStore.customized(.ask, .floor))
        XCTAssertNil(PromptStore.floorOverride(for: .ask))
        // Blank → omit (falls back to the bridge's built-in floor).
        PromptStore.save(.ask, .floor, text: "", default: "REC FLOOR")
        XCTAssertNil(PromptStore.floorOverride(for: .ask))
    }

    func testFloorOverrideSentWhenCustomizedAndDiffers() {
        PromptStore.save(.ask, .floor, text: "WEAKER FLOOR", default: "REC FLOOR")
        XCTAssertTrue(PromptStore.customized(.ask, .floor))
        XCTAssertEqual(PromptStore.floorOverride(for: .ask), "WEAKER FLOOR")
    }

    func testFloorAndWrapperSlotsAreIndependent() {
        // Saving the floor must not disturb the wrapper slot...
        PromptStore.save(.ask, .floor, text: "WEAKER FLOOR", default: "REC FLOOR")
        XCTAssertNil(PromptStore.wrapperOverride(for: .ask))
        XCTAssertEqual(PromptStore.text(.ask, .wrapper), "")
        // ...and vice-versa.
        PromptStore.save(.ask, .wrapper, text: "MY WRAP", default: "DEFAULT WRAP")
        XCTAssertEqual(PromptStore.floorOverride(for: .ask), "WEAKER FLOOR")
        XCTAssertEqual(PromptStore.wrapperOverride(for: .ask), "MY WRAP")
    }

    func testResetToDefaultClearsCustomized() {
        PromptStore.save(.ask, .wrapper, text: "MY WRAP", default: "DEFAULT WRAP")
        XCTAssertTrue(PromptStore.customized(.ask, .wrapper))
        PromptStore.resetToDefault(.ask, .wrapper, default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.ask, .wrapper))
        XCTAssertEqual(PromptStore.text(.ask, .wrapper), "DEFAULT WRAP")
        XCTAssertNil(PromptStore.wrapperOverride(for: .ask))
    }

    func testResetFloorToDefaultClearsCustomized() {
        PromptStore.save(.ask, .floor, text: "WEAKER FLOOR", default: "REC FLOOR")
        XCTAssertTrue(PromptStore.customized(.ask, .floor))
        PromptStore.resetToDefault(.ask, .floor, default: "REC FLOOR")
        XCTAssertFalse(PromptStore.customized(.ask, .floor))
        XCTAssertEqual(PromptStore.text(.ask, .floor), "REC FLOOR")
        XCTAssertNil(PromptStore.floorOverride(for: .ask))
    }

    // MARK: - RunCoordinator forwards the override into send

    /// Captures what `send` was called with, then returns an inline reply so the
    /// turn completes immediately (no poll loop).
    @MainActor
    private final class CapturingClient: JesseClientProtocol {
        private(set) var sendCalled = false
        private(set) var capturedInstructions: String?
        private(set) var capturedFloor: String?
        private(set) var capturedVoice = false
        var onSend: (() -> Void)?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCalled = true
            capturedInstructions = instructions
            capturedFloor = floorOverride
            capturedVoice = voice
            onSend?()
            return .reply(JesseReply(text: "ok", sessionId: nil), jobId: nil)
        }

        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: nil))
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func runSend(instructions: @escaping (JesseMode) -> String? = { _ in nil },
                         floor: @escaping (JesseMode) -> String? = { _ in nil },
                         mode: JesseMode, voice: Bool) async throws -> CapturingClient {
        let context = try makeContext()
        let fake = CapturingClient()
        let sent = expectation(description: "send called")
        fake.onSend = { sent.fulfill() }
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "h", port: 8765, token: "t") },
            makeClient: { _ in fake },
            instructions: instructions,
            floor: floor)
        let thread = JesseThread(mode: mode)
        coordinator.send(thread: thread, text: "hi", voice: voice, context: context)
        await fulfillment(of: [sent], timeout: 2)
        return fake
    }

    @MainActor
    func testSendForwardsInstructionsWhenCustomized() async throws {
        let fake = try await runSend(instructions: { _ in "MY CUSTOM WRAPPER" },
                                     mode: .ask, voice: false)
        XCTAssertTrue(fake.sendCalled)
        XCTAssertEqual(fake.capturedInstructions, "MY CUSTOM WRAPPER")
    }

    @MainActor
    func testSendOmitsInstructionsWhenNotCustomized() async throws {
        let fake = try await runSend(instructions: { _ in nil }, mode: .ask, voice: false)
        XCTAssertTrue(fake.sendCalled)
        XCTAssertNil(fake.capturedInstructions, "no override when the mode isn't customized")
    }

    @MainActor
    func testVoiceSendStillForwardsOverride() async throws {
        let fake = try await runSend(instructions: { _ in "VOICE WRAP" },
                                     mode: .ask, voice: true)
        XCTAssertEqual(fake.capturedInstructions, "VOICE WRAP")
        XCTAssertTrue(fake.capturedVoice, "voice flag must still be sent alongside the override")
    }

    @MainActor
    func testSendForwardsFloorOverrideWhenCustomized() async throws {
        let fake = try await runSend(floor: { _ in "WEAKER FLOOR" }, mode: .ask, voice: false)
        XCTAssertTrue(fake.sendCalled)
        XCTAssertEqual(fake.capturedFloor, "WEAKER FLOOR")
    }

    @MainActor
    func testSendOmitsFloorOverrideWhenNotCustomized() async throws {
        let fake = try await runSend(mode: .ask, voice: false)
        XCTAssertTrue(fake.sendCalled)
        XCTAssertNil(fake.capturedFloor, "no floor override when the mode isn't customized")
        // The default provider path (no injected closures) still compiles/runs.
    }

    @MainActor
    func testSendForwardsBothOverridesTogether() async throws {
        let fake = try await runSend(instructions: { _ in "WRAP" },
                                     floor: { _ in "FLOOR" }, mode: .tell, voice: false)
        XCTAssertEqual(fake.capturedInstructions, "WRAP")
        XCTAssertEqual(fake.capturedFloor, "FLOOR")
    }
}
