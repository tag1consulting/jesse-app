import SwiftUI

// The two pieces of UI the recording flow needs, and they live in the package rather
// than in either app for the reason the diet and day dashboards do: the iPhone composer
// and the Mac composer show the SAME language picker and the SAME progress row, and a
// copy in each target is two wordings that drift.
//
// Both are thin. Every decision they draw — which languages, in what order, what the
// progress means, what a failure says — belongs to `RecordingAttachment` and is tested
// there. These render it.

/// The language choice, raised once a recording has been read and before a word of it is
/// transcribed.
///
/// It is a sheet with an explicit confirm rather than an inline picker that starts on
/// selection, because starting is expensive: the wrong language on an hour of audio is
/// several minutes and a page of nonsense. The device's own languages are at the top of
/// the list (see `TranscriptionLocalePolicy.menu`), and it opens on the last one used.
public struct RecordingLanguageSheet: View {
    @Bindable var model: RecordingAttachment
    @Environment(\.dismiss) private var dismiss

    public init(model: RecordingAttachment) { self.model = model }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.languages, id: \.identifier) { locale in
                        Button {
                            model.selectedLanguage = locale
                        } label: {
                            HStack {
                                Text(TranscriptionLocalePolicy.displayName(locale))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if model.selectedLanguage?.identifier == locale.identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(
                            model.selectedLanguage?.identifier == locale.identifier
                                ? [.isSelected] : [])
                    }
                } header: {
                    Text("Language spoken in “\(model.sourceName)”")
                } footer: {
                    Text("Transcribed on this device. The recording is never uploaded, and it is deleted as soon as the text exists.")
                }
            }
            .navigationTitle("Transcribe Recording")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transcribe") { model.confirmLanguage() }
                        .disabled(model.selectedLanguage == nil)
                }
            }
        }
    }
}

/// The running transcription: which phase, how far, and a Cancel that means it.
///
/// It names the phase because the three waits are not interchangeable — a first
/// recording in a new language downloads a speech model before it recognizes anything,
/// and a bar that sat at zero through that would read as broken rather than busy.
public struct RecordingProgressBar: View {
    let update: TranscriptionUpdate
    let sourceName: String
    let onCancel: () -> Void

    public init(update: TranscriptionUpdate, sourceName: String, onCancel: @escaping () -> Void) {
        self.update = update
        self.sourceName = sourceName
        self.onCancel = onCancel
    }

    private var label: String {
        switch update.phase {
        case .preparing:
            return "Preparing “\(sourceName)”…"
        case .downloadingModel:
            return "Downloading the speech model…"
        case .transcribing:
            return "Transcribing “\(sourceName)”… \(Int(update.fraction * 100))%"
        }
    }

    public var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: update.fraction)
                    .progressViewStyle(.linear)
            }
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
