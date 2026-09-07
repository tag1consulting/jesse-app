import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// What a recording turns out to be once it has actually been opened.
public struct AudioFileFacts: Sendable, Equatable {
    public let durationSeconds: Double
    public let sampleRate: Double

    public init(durationSeconds: Double, sampleRate: Double) {
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
    }
}

/// Opening a file and answering "is this audio, and how long is it?".
///
/// A seam rather than a free function so the composer's model — the piece that owns the
/// rejection message, the progress and the cleanup — can be tested against a file that
/// does not exist.
public protocol AudioFileProbing: Sendable {
    /// - Throws: `TranscriptionFailure.unreadableFile` for anything that is not audio
    ///   this device can open, including a file with the right extension and the wrong
    ///   contents.
    func facts(forFileAt url: URL) throws -> AudioFileFacts
}

/// The production probe.
///
/// It uses `AVAudioFile` deliberately, rather than a lighter-weight header sniff or an
/// `AVURLAsset` metadata read, because `AVAudioFile` is precisely the object
/// `SpeechAnalyzer` is handed. Validating with the same reader that will do the work
/// means "the probe accepted it" and "the transcriber can read it" cannot disagree — a
/// file renamed to `.m4a`, or truncated mid-download, fails here with a specific message
/// instead of failing later as an opaque engine error.
public struct AVAudioFileProbe: AudioFileProbing {
    public init() {}

    public func facts(forFileAt url: URL) throws -> AudioFileFacts {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw TranscriptionFailure.unreadableFile
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { throw TranscriptionFailure.unreadableFile }
        return AudioFileFacts(durationSeconds: Double(file.length) / rate, sampleRate: rate)
    }
}

/// The recorder outputs the pickers accept.
///
/// The named types are the ones a person actually arrives with — Voice Memos and the
/// iPhone's own recorders write `m4a`, everything else in the list is what a downloaded
/// or desktop-made file turns out to be. `.audio` is included as the umbrella so the
/// picker does not grey out a perfectly transcribable file merely because this list did
/// not anticipate its container; whatever is picked is still opened by `AVAudioFileProbe`
/// before anything else happens, and that is the real gate.
public enum AudioRecordingTypes {
    public static let contentTypes: [UTType] = {
        var types: [UTType] = [.mpeg4Audio, .mp3, .wav, .aiff]
        if let caf = UTType("com.apple.coreaudio-format") { types.append(caf) }
        types.append(.audio)
        return types
    }()
}
