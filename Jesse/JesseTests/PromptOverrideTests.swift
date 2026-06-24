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
                                        attachments: [])
        XCTAssertEqual(b["instructions"] as? String, "CUSTOM WRAP")
    }

    func testRequestBodyOmitsInstructionsWhenNil() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: false, instructions: nil,
                                        attachments: [])
        XCTAssertNil(b["instructions"], "an absent override must omit the field")
        // Byte-compat: an ordinary turn carries only mode + text.
        XCTAssertEqual(b["mode"] as? String, "ask")
        XCTAssertEqual(b["text"] as? String, "hi")
        XCTAssertNil(b["voice"])
    }

    func testRequestBodyOmitsBlankInstructions() {
        let b = JesseClient.requestBody(mode: .tell, text: "hi", sessionId: nil,
                                        voice: false, instructions: "   \n\t",
                                        attachments: [])
        XCTAssertNil(b["instructions"], "a blank override means use the default → omit")
    }

    func testRequestBodyVoiceAndOverrideCoexist() {
        let b = JesseClient.requestBody(mode: .ask, text: "hi", sessionId: nil,
                                        voice: true, instructions: "VOICE WRAP",
                                        attachments: [])
        XCTAssertEqual(b["voice"] as? Bool, true)
        XCTAssertEqual(b["instructions"] as? String, "VOICE WRAP")
    }

    // MARK: - decodePrompts (GET /jesse/prompts)

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h:8765/jesse/prompts")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testDecodePromptsValid() throws {
        let json = #"{"ask":"ASK WRAP","tell":"TELL WRAP"}"#.data(using: .utf8)!
        let p = try JesseClient.decodePrompts(data: json, resp: http(200))
        XCTAssertEqual(p.ask, "ASK WRAP")
        XCTAssertEqual(p.tell, "TELL WRAP")
    }

    func testDecodePromptsNon2xxThrows() {
        let json = "Unauthorized".data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(401)))
    }

    func testDecodePromptsMissingFieldThrows() {
        let json = #"{"ask":"only ask"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodePrompts(data: json, resp: http(200)))
    }

    // MARK: - PromptStore override decision

    private func clearPromptDefaults() {
        let d = UserDefaults.standard
        for mode in ["ask", "tell"] {
            for suffix in ["text", "customized", "default"] {
                d.removeObject(forKey: "jesse.prompt.\(mode).\(suffix)")
            }
        }
    }

    override func setUp() { super.setUp(); clearPromptDefaults() }
    override func tearDown() { clearPromptDefaults(); super.tearDown() }

    func testOverrideNilWhenUntouched() {
        XCTAssertNil(PromptStore.override(for: .ask))
        XCTAssertNil(PromptStore.override(for: .tell))
    }

    func testOverrideSentWhenCustomizedAndDiffers() {
        PromptStore.save(.ask, text: "MY WRAP", default: "DEFAULT WRAP")
        XCTAssertTrue(PromptStore.customized(.ask))
        XCTAssertEqual(PromptStore.override(for: .ask), "MY WRAP")
    }

    func testOverrideOmittedWhenEqualsDefault() {
        PromptStore.save(.ask, text: "DEFAULT WRAP", default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.ask))
        XCTAssertNil(PromptStore.override(for: .ask))
    }

    func testOverrideOmittedWhenEmpty() {
        PromptStore.save(.tell, text: "", default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.tell))
        XCTAssertNil(PromptStore.override(for: .tell))
    }

    func testResetToDefaultClearsCustomized() {
        PromptStore.save(.ask, text: "MY WRAP", default: "DEFAULT WRAP")
        XCTAssertTrue(PromptStore.customized(.ask))
        PromptStore.resetToDefault(.ask, default: "DEFAULT WRAP")
        XCTAssertFalse(PromptStore.customized(.ask))
        XCTAssertEqual(PromptStore.text(.ask), "DEFAULT WRAP")
        XCTAssertNil(PromptStore.override(for: .ask))
    }

    // MARK: - RunCoordinator forwards the override into send

    /// Captures what `send` was called with, then returns an inline reply so the
    /// turn completes immediately (no poll loop).
    @MainActor
    private final class CapturingClient: JesseClientProtocol {
        private(set) var sendCalled = false
        private(set) var capturedInstructions: String?
        private(set) var capturedVoice = false
        var onSend: (() -> Void)?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCalled = true
            capturedInstructions = instructions
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
    private func runSend(instructions: @escaping (JesseMode) -> String?,
                         mode: JesseMode, voice: Bool) async throws -> CapturingClient {
        let context = try makeContext()
        let fake = CapturingClient()
        let sent = expectation(description: "send called")
        fake.onSend = { sent.fulfill() }
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "h", port: 8765, token: "t") },
            makeClient: { _ in fake },
            instructions: instructions)
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
}
