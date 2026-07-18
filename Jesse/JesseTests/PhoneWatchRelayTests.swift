import XCTest
import SwiftData
@testable import Jesse

/// The phone-side STT → relay seam (`WatchTurnHandler`). Drives it with a FAKE
/// transcriber and the same `JesseClientProtocol` fake the relay tests use, so it
/// runs with no microphone, no Speech framework, and no watch hardware. Asserts:
/// the fake transcript is exactly what gets relayed, the turn is `voice: true`, the
/// thread is tagged `.watch`, the reply carries displayText/spokenText, the
/// dictation fallback bypasses transcription, and a transcription failure yields a
/// clean `ok: false` reply that never even starts a turn.
@MainActor
final class PhoneWatchRelayTests: XCTestCase {

    /// Records the audio it was handed and returns a scripted transcript (or nil).
    private final class FakeTranscriber: AudioTranscribing, @unchecked Sendable {
        let transcript: String?
        private(set) var received: [Data] = []
        init(transcript: String?) { self.transcript = transcript }
        func transcribe(_ audio: Data) async -> String? {
            received.append(audio)
            return transcript
        }
    }

    /// The same fake shape `WatchRelayTests` uses: counts sends, returns a fixed
    /// reply (or fails at the poll).
    @MainActor
    private final class RelayFakeClient: JesseClientProtocol {
        var sendCount = 0
        var lastText: String?
        var lastVoice: Bool?
        let replyText: String
        let failAtResult: Bool

        init(replyText: String, failAtResult: Bool = false) {
            self.replyText = replyText
            self.failAtResult = failAtResult
        }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCount += 1
            lastText = text
            lastVoice = voice
            return .running(jobId: "job-1")
        }
        func result(jobId: String) async throws -> JesseResultState {
            if failAtResult { throw JesseError.timedOut("asleep") }
            return .done(JesseReply(text: replyText, sessionId: "sess-1"))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
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
    private func makeHandler(_ fake: RelayFakeClient, transcriber: FakeTranscriber) -> WatchTurnHandler {
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            pollSleep: { _ in })
        return WatchTurnHandler(transcriber: transcriber, relay: WatchRelay(coordinator: coordinator))
    }

    // MARK: - Audio path: the transcript is what gets relayed, voice:true, tagged watch

    @MainActor
    func testAudioIsTranscribedAndRelayedTaggedWatch() async throws {
        let transcriber = FakeTranscriber(transcript: "add milk to the shopping list")
        let fake = RelayFakeClient(
            replyText: "Added milk to the list.\nSPOKEN: Done — milk is on your list.")
        let handler = makeHandler(fake, transcriber: transcriber)
        let context = try makeContext()

        let audio = Data([0x01, 0x02, 0x03, 0x04])
        let request = WatchRequest(requestId: UUID(), mode: .tell, audio: audio)
        let reply = await handler.handle(request, context: context)

        // The exact fake transcript reached the relay/turn, with voice:true.
        XCTAssertEqual(fake.lastText, "add milk to the shopping list")
        XCTAssertEqual(fake.lastVoice, true)
        XCTAssertEqual(transcriber.received, [audio], "the audio bytes were handed to the transcriber")

        // The reply the watch renders.
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.requestId, request.requestId)
        XCTAssertEqual(reply.displayText, "Added milk to the list.")
        XCTAssertEqual(reply.spokenText, "Done — milk is on your list.")

        // The turn landed in history tagged .watch, with both turns persisted.
        let threads = try context.fetch(FetchDescriptor<JesseThread>())
        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.originValue, .watch)
        XCTAssertEqual(thread.id, reply.threadId)
        XCTAssertEqual(thread.orderedTurns.first?.text, "add milk to the shopping list")
        XCTAssertEqual(thread.orderedTurns.map(\.roleValue), [.user, .jesse])
    }

    // MARK: - Dictation fallback bypasses transcription

    @MainActor
    func testDictationFallbackSkipsTranscriberAndRelays() async throws {
        let transcriber = FakeTranscriber(transcript: "SHOULD NOT BE USED")
        let fake = RelayFakeClient(replyText: "Ok.\nSPOKEN: Ok.")
        let handler = makeHandler(fake, transcriber: transcriber)
        let context = try makeContext()

        let request = WatchRequest(requestId: UUID(), mode: .ask, transcript: "what is on today")
        let reply = await handler.handle(request, context: context)

        XCTAssertTrue(transcriber.received.isEmpty, "a dictated request must not hit the transcriber")
        XCTAssertEqual(fake.lastText, "what is on today")
        XCTAssertTrue(reply.ok)
    }

    // MARK: - Transcription failure yields a clean reply, no turn started

    @MainActor
    func testUnrecognizableAudioYieldsErrorAndNoTurn() async throws {
        let transcriber = FakeTranscriber(transcript: nil) // recognizer couldn't understand it
        let fake = RelayFakeClient(replyText: "unused")
        let handler = makeHandler(fake, transcriber: transcriber)
        let context = try makeContext()

        let request = WatchRequest(requestId: UUID(), mode: .ask, audio: Data([0x09]))
        let reply = await handler.handle(request, context: context)

        XCTAssertFalse(reply.ok)
        XCTAssertFalse(reply.error?.isEmpty ?? true)
        XCTAssertEqual(fake.sendCount, 0, "an unrecognizable clip must never start a turn")
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 0,
                       "and must not create a thread")
    }

    // MARK: - A relay failure is surfaced as an ok:false reply

    @MainActor
    func testRelayFailureBecomesFailureReply() async throws {
        let transcriber = FakeTranscriber(transcript: "will fail")
        let fake = RelayFakeClient(replyText: "unused", failAtResult: true)
        let handler = makeHandler(fake, transcriber: transcriber)
        let context = try makeContext()

        let request = WatchRequest(requestId: UUID(), mode: .ask, audio: Data([0x09]))
        let reply = await handler.handle(request, context: context)

        XCTAssertFalse(reply.ok)
        XCTAssertFalse(reply.error?.isEmpty ?? true)
        // The thread + user turn were still created (the relay guarantees that).
        XCTAssertEqual(reply.threadId.map { _ in true }, true)
        let thread = try XCTUnwrap(try context.fetch(FetchDescriptor<JesseThread>()).first)
        XCTAssertEqual(thread.originValue, .watch)
        XCTAssertEqual(thread.orderedTurns.map(\.roleValue), [.user])
    }
}
