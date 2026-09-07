import Synchronization
import XCTest
@testable import JesseSpeech

// The flow itself: pick, choose a language, transcribe, compose — and, on every single
// way out of that, delete the audio.
//
// Driven entirely through the injected seams, so none of this needs a microphone, a
// speech model, a permission prompt, or a minute of wall clock. The fake transcriber
// below is where an hour of Italian, a wedged recognizer and a denied permission all
// come from.

// MARK: - Fakes

/// A transcriber under the test's control: it can succeed, fail in any of the named
/// ways, or block until the caller's task is cancelled.
private final class FakeTranscriber: AudioFileTranscribing, Sendable {
    enum Behaviour: Sendable {
        case succeed(String)
        case fail(TranscriptionFailure)
        /// Report progress, then wait forever — the shape a Cancel has to interrupt.
        case hang
    }

    private struct State {
        var behaviour: Behaviour
        var calls: [Call] = []
    }

    struct Call: Sendable {
        let url: URL
        let locale: Locale
    }

    // `Mutex` rather than `NSLock`: locking is unavailable from an async context, and
    // `transcribe` is async.
    private let state: Mutex<State>

    init(_ behaviour: Behaviour) { state = Mutex(State(behaviour: behaviour)) }

    var behaviour: Behaviour {
        get { state.withLock { $0.behaviour } }
        set { state.withLock { $0.behaviour = newValue } }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func transcribe(fileAt url: URL,
                    locale: Locale,
                    onProgress: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws -> String {
        let behaviour = state.withLock { state -> Behaviour in
            state.calls.append(Call(url: url, locale: locale))
            return state.behaviour
        }

        onProgress(TranscriptionUpdate(phase: .transcribing, fraction: 0.5, transcript: "partial"))
        switch behaviour {
        case .succeed(let text):
            return text
        case .fail(let failure):
            throw failure
        case .hang:
            // Sleep in slices so cancellation is observed promptly; a real engine's
            // cancellation arrives the same way.
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

private struct FakeProbe: AudioFileProbing {
    var seconds: Double = 192
    var failure: TranscriptionFailure?

    func facts(forFileAt url: URL) throws -> AudioFileFacts {
        if let failure { throw failure }
        return AudioFileFacts(durationSeconds: seconds, sampleRate: 16_000)
    }
}

/// A `UserDefaults`-free memory of the last language, so tests never write to the
/// process's real defaults.
private final class LanguageMemory: Sendable {
    private let value = Mutex<String?>(nil)
    var stored: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

@MainActor
final class RecordingAttachmentTests: XCTestCase {

    // Initialized inline rather than in `setUp`: XCTest builds a fresh instance per test
    // method, so these are already per-test, and a `@MainActor` class cannot touch its own
    // isolated state from the nonisolated `setUpWithError` override.
    private let workRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("attach-work-\(UUID().uuidString)", isDirectory: true)
    private let handoffRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("attach-inbox-\(UUID().uuidString)", isDirectory: true)
    private let memory = LanguageMemory()

    private var workingCopy: RecordingWorkingCopy { RecordingWorkingCopy(directory: workRoot) }
    private var handoffStore: RecordingHandoffStore { RecordingHandoffStore(directory: handoffRoot) }

    private let supported = [
        Locale(identifier: "en-US"),
        Locale(identifier: "it-IT"),
        Locale(identifier: "de-DE"),
    ]

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: workRoot)
        try? FileManager.default.removeItem(at: handoffRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(_ transcriber: FakeTranscriber,
                           probe: FakeProbe = FakeProbe(),
                           supported: [Locale]? = nil,
                           preferred: [String] = ["en-US"]) -> RecordingAttachment {
        let locales = supported ?? self.supported
        let memory = self.memory
        return RecordingAttachment(
            transcriber: transcriber,
            probe: probe,
            workingCopy: workingCopy,
            handoffStore: handoffStore,
            supportedLocales: { locales },
            preferredLanguages: { preferred },
            readLastLanguage: { memory.stored },
            writeLastLanguage: { memory.stored = $0 })
    }

    /// A file standing in for something the user picked out of Files.
    private func pickedFile(named name: String = "memo.m4a") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    private var workingFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: workRoot.path)) ?? []).sorted()
    }

    private var inboxFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: handoffRoot.path)) ?? []).sorted()
    }

    /// Wait for `condition`, so a test never depends on how many hops an async chain
    /// happens to take. Fails rather than hanging.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - The happy path

    func testAPickedRecordingBecomesAComposedMessageBody() async throws {
        let transcriber = FakeTranscriber(.succeed("Buongiorno, sono il pizzaiolo."))
        let model = makeModel(transcriber)

        await model.begin(pickedFileAt: try pickedFile(named: "Nuova registrazione 3.m4a"))
        XCTAssertEqual(model.stage, .choosingLanguage)
        XCTAssertEqual(model.sourceName, "Nuova registrazione 3.m4a")

        model.selectedLanguage = Locale(identifier: "it-IT")
        model.confirmLanguage()
        await waitUntil("the transcript to land") { model.completed != nil }

        let completed = try XCTUnwrap(model.takeCompleted())
        XCTAssertEqual(completed.transcript, "Buongiorno, sono il pizzaiolo.")
        XCTAssertEqual(completed.durationSeconds, 192)
        XCTAssertEqual(completed.sourceName, "Nuova registrazione 3.m4a")

        // Typed text is composed at the END, so anything typed while an hour of audio
        // was transcribing survives.
        XCTAssertEqual(completed.messageBody(typed: "From the site visit."), """
        From the site visit.

        Recording: “Nuova registrazione 3.m4a” · 3m 12s · \(completed.language)

        Buongiorno, sono il pizzaiolo.
        """)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.stage, .idle)
        XCTAssertEqual(workingFiles, [], "the working copy must be gone once the transcript exists")
    }

    func testTakeCompletedYieldsTheTranscriptExactlyOnce() async throws {
        let model = makeModel(FakeTranscriber(.succeed("Hello.")))
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()
        await waitUntil("completion") { model.completed != nil }

        XCTAssertNotNil(model.takeCompleted())
        XCTAssertNil(model.takeCompleted(), "one recording must never land in two composers")
    }

    func testTheTranscriberIsGivenTheAppsOwnCopyNotThePickersURL() async throws {
        // The picker's URL is security-scoped into somebody else's container, and the
        // engine reads for minutes. It must be handed our copy.
        let transcriber = FakeTranscriber(.succeed("Hello."))
        let model = makeModel(transcriber)
        let source = try pickedFile()
        await model.begin(pickedFileAt: source)
        model.confirmLanguage()
        await waitUntil("completion") { model.completed != nil }

        let used = try XCTUnwrap(transcriber.calls.first?.url)
        XCTAssertNotEqual(used, source)
        XCTAssertEqual(used.deletingLastPathComponent().standardizedFileURL,
                       workRoot.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the user's own recording is never touched")
    }

    // MARK: - Language

    func testTheLanguagePickerOpensOnTheRememberedChoiceAndRemembersTheNewOne() async throws {
        memory.stored = "it-IT"
        let model = makeModel(FakeTranscriber(.succeed("Ciao.")))
        await model.begin(pickedFileAt: try pickedFile())
        XCTAssertEqual(model.selectedLanguage, Locale(identifier: "it-IT"))

        model.selectedLanguage = Locale(identifier: "de-DE")
        model.confirmLanguage()
        await waitUntil("completion") { model.completed != nil }
        XCTAssertEqual(memory.stored, "de-DE")
    }

    func testSwitchingLanguageBetweenTwoAttachmentsWorksWithoutRebuildingTheModel() async throws {
        // The acceptance criterion, literally: two recordings, two languages, one
        // running app.
        let transcriber = FakeTranscriber(.succeed("Ciao."))
        let model = makeModel(transcriber)

        await model.begin(pickedFileAt: try pickedFile(named: "one.m4a"))
        model.selectedLanguage = Locale(identifier: "it-IT")
        model.confirmLanguage()
        await waitUntil("the first transcript") { model.completed != nil }
        _ = model.takeCompleted()

        transcriber.behaviour = .succeed("Hello.")
        await model.begin(pickedFileAt: try pickedFile(named: "two.m4a"))
        // It opens on Italian (remembered) and the user changes it.
        XCTAssertEqual(model.selectedLanguage, Locale(identifier: "it-IT"))
        model.selectedLanguage = Locale(identifier: "en-US")
        model.confirmLanguage()
        await waitUntil("the second transcript") { model.completed != nil }

        XCTAssertEqual(transcriber.calls.map(\.locale.identifier), ["it-IT", "en-US"])
        XCTAssertEqual(model.takeCompleted()?.transcript, "Hello.")
        XCTAssertEqual(workingFiles, [])
    }

    func testTheLanguageMenuIsOfferedDevicePreferredFirst() async throws {
        let model = makeModel(FakeTranscriber(.succeed("x")), preferred: ["it-IT"])
        await model.begin(pickedFileAt: try pickedFile())
        XCTAssertEqual(model.languages.first, Locale(identifier: "it-IT"))
        XCTAssertEqual(model.languages.count, supported.count)
    }

    func testADeviceThatSupportsNoLanguageSaysSoRatherThanOfferingAnEmptyPicker() async throws {
        let model = makeModel(FakeTranscriber(.succeed("x")), supported: [])
        await model.begin(pickedFileAt: try pickedFile())
        XCTAssertEqual(model.stage, .idle)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(workingFiles, [])
    }

    // MARK: - Progress and cancellation

    func testProgressIsPublishedWhileItRuns() async throws {
        let model = makeModel(FakeTranscriber(.hang))
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()

        await waitUntil("progress") {
            if case .running(let update) = model.stage { return update.fraction > 0 }
            return false
        }
        guard case .running(let update) = model.stage else { return XCTFail("expected .running") }
        XCTAssertEqual(update.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(update.transcript, "partial")
        XCTAssertTrue(model.isBusy)

        model.cancel()
    }

    func testCancelStopsTheRunDeletesTheAudioAndSaysNothing() async throws {
        let model = makeModel(FakeTranscriber(.hang))
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()
        await waitUntil("the run to start") { model.isBusy }
        XCTAssertEqual(workingFiles.count, 1)

        model.cancel()

        XCTAssertEqual(model.stage, .idle)
        XCTAssertNil(model.errorMessage, "the user cancelled; they do not need to be told")
        XCTAssertNil(model.completed)
        XCTAssertEqual(workingFiles, [], "cancellation is an exit path like any other")
    }

    func testProgressArrivingAfterACancelCannotResurrectTheProgressView() async throws {
        // A callback already in flight when Cancel is tapped must not put the sheet back.
        let model = makeModel(FakeTranscriber(.hang))
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()
        await waitUntil("the run to start") { model.isBusy }
        model.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.stage, .idle)
    }

    func testAbandoningTheLanguageSheetDeletesTheAudioToo() async throws {
        // Dismissed without choosing is still a copy of a private recording on disk.
        let model = makeModel(FakeTranscriber(.succeed("x")))
        await model.begin(pickedFileAt: try pickedFile())
        XCTAssertEqual(workingFiles.count, 1)
        model.abandon()
        XCTAssertEqual(model.stage, .idle)
        XCTAssertEqual(workingFiles, [])
    }

    // MARK: - Failures

    func testAnUnreadableFileIsRejectedByNameAndLeavesNothingBehind() async throws {
        let model = makeModel(FakeTranscriber(.succeed("x")),
                              probe: FakeProbe(failure: .unreadableFile))
        await model.begin(pickedFileAt: try pickedFile(named: "notes.pdf"))
        XCTAssertEqual(model.errorMessage,
                       TranscriptionFailure.unreadableFile.message(sourceName: "notes.pdf"))
        XCTAssertEqual(model.stage, .idle)
        XCTAssertEqual(workingFiles, [])
    }

    func testEveryEngineFailureReachesTheComposerAsItsOwnSentenceAndCleansUp() async throws {
        let cases: [TranscriptionFailure] = [
            .speechPermissionDenied,
            .localeUnavailable(language: "Italian"),
            .modelUnavailable(language: "Italian", reason: "no space left"),
            .noSpeechFound,
            .stalled,
            .engineFailed(reason: "the recognizer died"),
        ]
        for failure in cases {
            let model = makeModel(FakeTranscriber(.fail(failure)))
            await model.begin(pickedFileAt: try pickedFile(named: "memo.m4a"))
            model.confirmLanguage()
            await waitUntil("the failure to surface") { model.errorMessage != nil }

            XCTAssertEqual(model.errorMessage, failure.message(sourceName: "memo.m4a"))
            XCTAssertNil(model.completed)
            XCTAssertEqual(model.stage, .idle)
            XCTAssertEqual(workingFiles, [], "a failed run leaves no audio behind either")
        }
    }

    func testDismissErrorClearsTheMessageSoTheNextAttemptStartsClean() async throws {
        let model = makeModel(FakeTranscriber(.fail(.speechPermissionDenied)))
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()
        await waitUntil("the failure") { model.errorMessage != nil }
        model.dismissError()
        XCTAssertNil(model.errorMessage)
    }

    func testRetryingAfterADeniedPermissionUsesTheSameModel() async throws {
        // "A path to retry after granting it": the model must be reusable, not wedged.
        let transcriber = FakeTranscriber(.fail(.speechPermissionDenied))
        let model = makeModel(transcriber)
        await model.begin(pickedFileAt: try pickedFile())
        model.confirmLanguage()
        await waitUntil("the denial") { model.errorMessage != nil }

        transcriber.behaviour = .succeed("Granted now.")
        await model.begin(pickedFileAt: try pickedFile())
        XCTAssertNil(model.errorMessage, "starting again clears the previous complaint")
        model.confirmLanguage()
        await waitUntil("the retry") { model.completed != nil }
        XCTAssertEqual(model.takeCompleted()?.transcript, "Granted now.")
    }

    // MARK: - The share hand-off

    func testAHandoffIsTranscribedAndBothCopiesAreDeleted() async throws {
        let source = try pickedFile(named: "Nuova registrazione 3.m4a")
        let handoff = try handoffStore.stage(copying: source,
                                             originalName: "Nuova registrazione 3.m4a",
                                             durationSeconds: 192)
        XCTAssertEqual(inboxFiles.count, 2)

        let model = makeModel(FakeTranscriber(.succeed("Buongiorno.")))
        await model.begin(handoff: handoff)
        model.selectedLanguage = Locale(identifier: "it-IT")
        model.confirmLanguage()
        await waitUntil("the transcript") { model.completed != nil }

        XCTAssertEqual(model.takeCompleted()?.sourceName, "Nuova registrazione 3.m4a")
        XCTAssertEqual(workingFiles, [], "no working copy survives")
        XCTAssertEqual(inboxFiles, [], "and neither does the shared one")
        XCTAssertTrue(handoffStore.pending().isEmpty)
    }

    func testAFailedHandoffStillClearsTheSharedInbox() async throws {
        // Otherwise a recording that cannot be transcribed is retried forever, and a
        // copy of it lives in the app group until the sweep gets to it.
        let handoff = try handoffStore.stage(copying: try pickedFile(),
                                             originalName: "memo.m4a",
                                             durationSeconds: 5)
        let model = makeModel(FakeTranscriber(.fail(.noSpeechFound)))
        await model.begin(handoff: handoff)
        model.confirmLanguage()
        await waitUntil("the failure") { model.errorMessage != nil }

        XCTAssertEqual(inboxFiles, [])
        XCTAssertEqual(workingFiles, [])
    }

    func testCancellingAHandoffClearsTheSharedInbox() async throws {
        let handoff = try handoffStore.stage(copying: try pickedFile(),
                                             originalName: "memo.m4a",
                                             durationSeconds: 5)
        let model = makeModel(FakeTranscriber(.hang))
        await model.begin(handoff: handoff)
        model.confirmLanguage()
        await waitUntil("the run to start") { model.isBusy }
        model.cancel()

        XCTAssertEqual(inboxFiles, [])
        XCTAssertEqual(workingFiles, [])
    }

    // MARK: - Crash recovery

    func testSweepClearsAWorkingCopyACrashLeftBehindAndKeepsAWaitingShare() async throws {
        // Both halves of the launch-time story in one assertion: the picker's scratch
        // directory is emptied unconditionally, while a share that has not been opened
        // yet is exactly what must NOT be thrown away.
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: workRoot.appendingPathComponent("stale.m4a"))
        let waiting = try handoffStore.stage(copying: try pickedFile(),
                                             originalName: "memo.m4a",
                                             durationSeconds: 5)

        makeModel(FakeTranscriber(.succeed("x"))).sweepAbandonedAudio()

        XCTAssertEqual(workingFiles, [])
        XCTAssertEqual(handoffStore.pending().map(\.id), [waiting.id])
    }
}
