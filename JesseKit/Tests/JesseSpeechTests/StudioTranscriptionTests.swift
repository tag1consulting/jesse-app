import Synchronization
import XCTest
@testable import JesseSpeech

// The Studio-first path: a recording goes to the Jesse bridge on the Studio, is read there
// by stronger models than this device has, and comes back with its provenance and the
// places two engines disagreed. This device reads it only when the Studio cannot be
// reached — and says so.
//
// Every test runs against a scripted Studio and a scripted on-device engine, with an
// injected clock, so none of this needs a network, a bridge, a speech model or a second of
// wall-clock waiting.

// MARK: - Fakes

private final class FakeStudio: StudioTranscriptionTransport, Sendable {
    enum Upload: Sendable {
        case accept(StudioRunStatus)
        case fail(StudioTransportError)
    }

    struct Call: Sendable, Equatable {
        let url: URL
        let contentType: String
        let language: String
    }

    private struct State {
        var upload: Upload
        var polls: [Result<StudioRunStatus, StudioTransportError>]
        var uploads: [Call] = []
        var pollCount = 0
        var cancelled: [String] = []
    }

    private let state: Mutex<State>

    init(upload: Upload, polls: [Result<StudioRunStatus, StudioTransportError>] = []) {
        state = Mutex(State(upload: upload, polls: polls))
    }

    var uploads: [Call] { state.withLock { $0.uploads } }
    var pollCount: Int { state.withLock { $0.pollCount } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func upload(fileAt url: URL, contentType: String, language: String,
                onProgress: @escaping @Sendable (Double) -> Void) async throws -> StudioRunStatus {
        let upload = state.withLock { s -> Upload in
            s.uploads.append(Call(url: url, contentType: contentType, language: language))
            return s.upload
        }
        onProgress(1)
        switch upload {
        case .accept(let status): return status
        case .fail(let error): throw error
        }
    }

    func status(id: String) async throws -> StudioRunStatus {
        let next = state.withLock { s -> Result<StudioRunStatus, StudioTransportError> in
            s.pollCount += 1
            return s.polls.isEmpty ? .failure(.lostContact("the script ran out")) : s.polls.removeFirst()
        }
        return try next.get()
    }

    func cancel(id: String) async {
        state.withLock { $0.cancelled.append(id) }
    }
}

/// This device's engine: it reads whatever it is given, and records that it was asked.
private final class FakeDevice: AudioFileTranscribing, Sendable {
    private let calls = Mutex<[URL]>([])
    var called: [URL] { calls.withLock { $0 } }

    func transcribe(fileAt url: URL, locale: Locale,
                    onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> TranscriptionResult {
        calls.withLock { $0.append(url) }
        onProgress(TranscriptionUpdate(phase: .transcribing, fraction: 0.5))
        return TranscriptionResult(text: "Read on the device.", engine: TranscriptionPlace.thisDevice)
    }
}

/// A clock the fake sleep advances, so contact tolerance is exercised in no time at all.
private final class FakeClock: Sendable {
    private let seconds = Mutex<Double>(0)
    var now: Double { seconds.withLock { $0 } }
    func advance(_ by: Double) { seconds.withLock { $0 += by } }
}

private final class ProgressLog: Sendable {
    private let updates = Mutex<[TranscriptionUpdate]>([])
    var all: [TranscriptionUpdate] { updates.withLock { $0 } }
    func record(_ u: TranscriptionUpdate) { updates.withLock { $0.append(u) } }
}

// MARK: - Tests

final class StudioFirstTranscriberTests: XCTestCase {

    private let clock = FakeClock()
    private let log = ProgressLog()
    private let recording = URL(fileURLWithPath: "/tmp/working/5E1F.m4a")

    private func transcriber(_ studio: FakeStudio, device: FakeDevice = FakeDevice(),
                             tolerance: TimeInterval = 90,
                             sleep: (@Sendable (Duration) async throws -> Void)? = nil) -> StudioFirstTranscriber {
        let clock = self.clock
        return StudioFirstTranscriber(
            studio: studio,
            onDevice: device,
            pollInterval: .seconds(1),
            contactTolerance: tolerance,
            sleep: sleep ?? { _ in clock.advance(1) },
            now: { clock.now })
    }

    private func run(_ t: StudioFirstTranscriber, url: URL? = nil) async throws -> TranscriptionResult {
        let log = self.log
        return try await t.transcribe(fileAt: url ?? recording, locale: Locale(identifier: "it-IT")) {
            log.record($0)
        }
    }

    private func running(_ phase: String, engine: String? = nil, fraction: Double = 0) -> StudioRunStatus {
        StudioRunStatus(id: "tr-1", state: "running", phase: phase, fraction: fraction, engine: engine)
    }

    private let finished = StudioRunStatus(
        id: "tr-1", state: "done", phase: "done", fraction: 1,
        transcript: "  La raccolta è giovedì 14.  ",
        engines: [.init(id: "whisper-large-v3", label: "Whisper large-v3", role: "primary"),
                  .init(id: "whisper-large-v3-turbo", label: "Whisper large-v3 turbo", role: "second")],
        disagreements: [.init(startMs: 6_000, endMs: 11_000, primary: "14", alternative: "15")],
        notes: ["The engine looped once; the loop is collapsed and marked in the text."])

    func testAStudioRunDeliversItsTranscriptProvenanceAndDisagreements() async throws {
        let studio = FakeStudio(upload: .accept(running("queued")), polls: [
            .success(running("transcribing", engine: "Whisper large-v3", fraction: 0.5)),
            .success(running("second_reading", engine: "Whisper large-v3 turbo", fraction: 0.2)),
            .success(finished),
        ])
        let device = FakeDevice()
        let result = try await run(transcriber(studio, device: device))

        XCTAssertEqual(result.text, "La raccolta è giovedì 14.")
        XCTAssertEqual(result.engine, "the Studio (Whisper large-v3, checked against Whisper large-v3 turbo)")
        XCTAssertEqual(result.disagreements, [
            TranscriptDisagreement(startSeconds: 6, endSeconds: 11, primary: "14", alternative: "15"),
        ])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertNil(result.notice, "the usual path needs no notice")
        XCTAssertEqual(device.called, [], "this device never reads a recording the Studio read")
        XCTAssertEqual(studio.uploads, [FakeStudio.Call(url: recording, contentType: "audio/mp4", language: "it")])

        let phases = log.all.map(\.phase)
        XCTAssertEqual(phases.first, .uploading)
        XCTAssertTrue(phases.contains(.queued))
        XCTAssertTrue(phases.contains(.secondReading))
        let reading = try XCTUnwrap(log.all.first { $0.phase == .transcribing })
        XCTAssertEqual(reading.engine, "the Studio · Whisper large-v3", "progress names the engine running")
        XCTAssertEqual(reading.fraction, 0.5, accuracy: 0.001)
    }

    func testAnUnreachableStudioFallsBackToThisDeviceAndSaysSo() async throws {
        let studio = FakeStudio(upload: .fail(.unavailable("could not connect to the server")))
        let device = FakeDevice()
        let result = try await run(transcriber(studio, device: device))

        XCTAssertEqual(result.text, "Read on the device.")
        XCTAssertEqual(result.engine, TranscriptionPlace.thisDevice)
        XCTAssertEqual(device.called, [recording])
        let notice = try XCTUnwrap(result.notice, "a fallback is never silent")
        XCTAssertTrue(notice.contains("could not connect to the server"), notice)
        XCTAssertTrue(notice.contains(TranscriptionPlace.thisDevice), notice)
        XCTAssertEqual(log.all.last?.engine, TranscriptionPlace.thisDevice,
                       "the progress row says who is reading once the fallback starts")
    }

    func testAStudioThatRefusesIsBelievedNotBypassed() async throws {
        let studio = FakeStudio(upload: .fail(.refused("the recording is larger than the Studio accepts")))
        let device = FakeDevice()
        do {
            _ = try await run(transcriber(studio, device: device))
            XCTFail("a refusal must surface")
        } catch let failure as TranscriptionFailure {
            XCTAssertEqual(failure, .studioRefused(reason: "the recording is larger than the Studio accepts"))
        }
        XCTAssertEqual(device.called, [], "the Studio was reached; its answer stands")
    }

    func testAFailedStudioRunReportsItsOwnReason() async throws {
        let failed = StudioRunStatus(id: "tr-1", state: "failed", phase: "failed",
                                     error: .init(kind: "engine_failed",
                                                  message: "The Studio's speech engine failed: out of memory."))
        do {
            _ = try await run(transcriber(FakeStudio(upload: .accept(running("queued")), polls: [.success(failed)])))
            XCTFail("expected a failure")
        } catch let failure as TranscriptionFailure {
            XCTAssertEqual(failure, .studioFailed(reason: "The Studio's speech engine failed: out of memory."))
        }

        let silent = StudioRunStatus(id: "tr-1", state: "failed", phase: "failed",
                                     error: .init(kind: "no_speech", message: "No speech was recognized."))
        do {
            _ = try await run(transcriber(FakeStudio(upload: .accept(running("queued")), polls: [.success(silent)])))
            XCTFail("expected a failure")
        } catch let failure as TranscriptionFailure {
            XCTAssertEqual(failure, .noSpeechFound, "no speech is no speech, wherever it was read")
        }
    }

    func testABriefSilenceIsRiddenOut() async throws {
        let studio = FakeStudio(upload: .accept(running("queued")), polls: [
            .failure(.lostContact("the network connection was lost")),
            .failure(.lostContact("the network connection was lost")),
            .success(finished),
        ])
        let device = FakeDevice()
        let result = try await run(transcriber(studio, device: device, tolerance: 90))
        XCTAssertEqual(result.text, "La raccolta è giovedì 14.")
        XCTAssertEqual(device.called, [], "a lift ride is not a reason to read it again here")
    }

    func testALongSilenceGivesUpOnTheStudioStopsItAndReadsHere() async throws {
        let silence = Array(repeating: Result<StudioRunStatus, StudioTransportError>.failure(.lostContact("timed out")),
                            count: 20)
        let studio = FakeStudio(upload: .accept(running("transcribing")), polls: silence)
        let device = FakeDevice()
        let result = try await run(transcriber(studio, device: device, tolerance: 3))

        XCTAssertEqual(result.text, "Read on the device.")
        XCTAssertTrue(result.notice?.contains("contact with it was lost") ?? false, result.notice ?? "nil")
        XCTAssertLessThan(studio.pollCount, 10, "it gives up at the tolerance, not at the end of the script")
        try await waitUntil { studio.cancelled == ["tr-1"] }
    }

    func testCancellingWhileItRunsTellsTheStudioToStop() async throws {
        let sleeps = Mutex(0)
        let studio = FakeStudio(upload: .accept(running("queued")),
                                polls: [.success(running("transcribing", engine: "Whisper large-v3"))])
        let t = transcriber(studio) { _ in
            let n = sleeps.withLock { $0 += 1; return $0 }
            if n >= 2 { throw CancellationError() }
        }
        do {
            _ = try await run(t)
            XCTFail("expected a cancel")
        } catch let failure as TranscriptionFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        try await waitUntil { studio.cancelled == ["tr-1"] }
    }

    func testAFileTheStudioCannotReadGoesStraightToThisDevice() async throws {
        let studio = FakeStudio(upload: .fail(.refused("should not be called")))
        let device = FakeDevice()
        let ogg = URL(fileURLWithPath: "/tmp/working/memo.ogg")
        let result = try await run(transcriber(studio, device: device), url: ogg)
        XCTAssertEqual(studio.uploads, [], "nothing is sent that the Studio would refuse")
        XCTAssertEqual(device.called, [ogg])
        XCTAssertTrue(result.notice?.contains(".ogg") ?? false, result.notice ?? "nil")
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out")
    }
}

final class StudioWireTests: XCTestCase {

    /// The bridge's own status JSON — the shape `bridge/src/speech/service.rs` writes —
    /// decodes, including the fields this side does not use.
    func testTheRunStatusDecodesTheBridgesOwnJSON() throws {
        let json = """
        {"id":"tr-7f3a","state":"done","phase":"done","fraction":1.0,"engine":null,
         "type":"audio/mp4","bytes":31457280,"language":"it","duration_secs":2820.0,
         "conditioning":{"applied":true,"reason":"noisy room"},
         "transcript":"Buonasera a tutti.",
         "engines":[{"id":"whisper-large-v3","label":"Whisper large-v3","role":"primary"},
                    {"id":"whisper-large-v3-turbo","label":"Whisper large-v3 turbo","role":"second"}],
         "disagreements":[{"start_ms":6000,"end_ms":11000,"primary":"14th.","alternative":"15th."}],
         "agreement":0.97,"notes":[],"error":null,"cancel_requested":false}
        """
        let status = try JSONDecoder().decode(StudioRunStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.state, "done")
        XCTAssertEqual(status.engines.map(\.role), ["primary", "second"])
        XCTAssertEqual(status.disagreements.first?.startMs, 6_000)
        XCTAssertEqual(status.transcript, "Buonasera a tutti.")

        let sparse = try JSONDecoder().decode(StudioRunStatus.self,
                                              from: Data(#"{"id":"tr-1","state":"running"}"#.utf8))
        XCTAssertEqual(sparse.phase, "running")
        XCTAssertEqual(sparse.engines, [])
    }

    /// THE ONLY REQUEST THAT CARRIES AUDIO goes to the paired bridge's own transcription
    /// route, on the host and token every turn already uses — and nowhere else. This is
    /// the device-side half of the rule that replaced "audio never goes on the network".
    func testTheOnlyRequestThatCarriesAudioGoesToThePairedBridge() throws {
        let endpoint = try XCTUnwrap(StudioEndpoint(baseURL: URL(string: "http://studio.example.ts.net:8765/"),
                                                    token: "tok"))
        let request = URLSessionStudioTransport.uploadRequest(endpoint: endpoint, language: "it",
                                                              contentType: "audio/mp4")
        XCTAssertEqual(request.url?.absoluteString,
                       "http://studio.example.ts.net:8765/jesse/transcriptions?language=it")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertNil(request.httpBody, "the recording is streamed from its file, not held in memory")
    }

    func testAnUnpairedDeviceHasNoStudio() {
        XCTAssertNil(StudioEndpoint(baseURL: nil, token: "tok"))
        XCTAssertNil(StudioEndpoint(baseURL: URL(string: "http://studio:8765/"), token: ""))
    }

    /// The fallback question, answered from the bridge's status code: could the Studio be
    /// reached to do this at all?
    func testUploadAnswersAreSortedByWhetherTheStudioCouldDoIt() {
        func isFallback(_ e: StudioTransportError) -> Bool {
            if case .unavailable = e { return true }
            return false
        }
        XCTAssertTrue(isFallback(.forUpload(status: 404, body: "")), "an older bridge has no route")
        XCTAssertTrue(isFallback(.forUpload(status: 503, body: "speech transcription is turned off")))
        XCTAssertFalse(isFallback(.forUpload(status: 413, body: "")), "too large is an answer")
        XCTAssertFalse(isFallback(.forUpload(status: 400, body: "not a recording")))
        XCTAssertFalse(isFallback(.forUpload(status: 401, body: "")))
        XCTAssertEqual(StudioTransportError.forUpload(status: 413, body: "over 1024 MB"), .refused("over 1024 MB"))
        XCTAssertTrue(isFallback(.forTransport(URLError(.cannotConnectToHost))))
    }

    func testContentTypesMatchWhatTheBridgeAdmits() {
        XCTAssertEqual(AudioContentType.forFile(URL(fileURLWithPath: "a.m4a")), "audio/mp4")
        XCTAssertEqual(AudioContentType.forFile(URL(fileURLWithPath: "a.WAV")), "audio/wav")
        XCTAssertEqual(AudioContentType.forFile(URL(fileURLWithPath: "a.aiff")), "audio/aiff")
        XCTAssertEqual(AudioContentType.forFile(URL(fileURLWithPath: "a.caf")), "audio/x-caf")
        XCTAssertEqual(AudioContentType.forFile(URL(fileURLWithPath: "a.mp3")), "audio/mpeg")
        XCTAssertNil(AudioContentType.forFile(URL(fileURLWithPath: "a.ogg")))
    }

    func testTheFallbackNoticeIsOneSentence() {
        let notice = StudioFirstTranscriber.fallbackNotice(reason: "could not connect to the server.",
                                                           place: "this device")
        XCTAssertEqual(notice, "The Studio wasn’t used (could not connect to the server), so this was transcribed on this device — expect more mistakes in names, numbers and dates.")
    }

    func testTheLanguageGoesAsItsBareCode() {
        XCTAssertEqual(StudioFirstTranscriber.languageTag(Locale(identifier: "it-IT")), "it")
        XCTAssertEqual(StudioFirstTranscriber.languageTag(Locale(identifier: "en_GB")), "en")
    }

    func testEveryPhaseHasItsOwnProgressSentence() {
        let phases: [TranscriptionUpdate.Phase] = [
            .preparing, .uploading, .queued, .downloadingModel, .conditioning,
            .transcribing, .secondReading, .reconciling,
        ]
        let labels = phases.map {
            RecordingProgressBar.label(for: TranscriptionUpdate(phase: $0, fraction: 0.4), sourceName: "memo.m4a")
        }
        XCTAssertEqual(Set(labels).count, phases.count, "\(labels)")
    }
}
