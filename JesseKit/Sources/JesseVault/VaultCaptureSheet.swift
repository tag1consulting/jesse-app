import Foundation
import SwiftUI

// ONE FIELD, AND A NOTE IT IS ABOUT.
//
// The reader is where a thought about a note actually happens: you open the kiln note, you
// remember the bricks were never ordered, and the place that thought has to end up is the
// vault. Before this it had to go through the composer, into the queue, and wait for the
// Studio to write it down — which is a hosted turn and a delay for a line of text the
// device could have written itself.
//
// The sheet is deliberately the smallest possible surface: a field, what it will do, and
// Save. No tags, no date picker, no destination picker — the destination is `Inbox/`, the
// morning routine files it from there, and every one of those controls would be a decision
// the person does not have to make.
//
// Available online too. A capture is a capture; making it offline-only would mean the
// fastest way to write something down stopped working the moment the Studio woke up.

public struct VaultCaptureSheet: View {
    @State private var model: VaultCaptureModel
    private let onDone: (InboxCaptureWrite?) -> Void
    /// Focus starts in the field: this sheet exists to be typed into, and a sheet that
    /// makes you tap once before typing is a sheet that gets used less.
    @FocusState private var focused: Bool

    public init(about: String? = nil,
                model: VaultCaptureModel? = nil,
                onDone: @escaping (InboxCaptureWrite?) -> Void = { _ in }) {
        _model = State(initialValue: model ?? VaultCaptureModel(about: about))
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A wrapping field rather than a `TextEditor`: a capture is normally one
                    // sentence, and a `TextEditor` in a `Form` on iOS is a box with no
                    // placeholder that grows to fill the sheet whether or not there is
                    // anything in it.
                    TextField("What do you want to remember?",
                              text: $model.text,
                              axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier(Self.fieldIdentifier)
                    // A row, not a `footer:` — a long footer ellipsises to one line on
                    // macOS, and this sentence is the whole explanation of where the text
                    // goes.
                    Text(model.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Capture")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Capture to Inbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                        .disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
        }
        .onAppear { focused = true }
        // The sheet closes when the capture has LANDED, never before: the file is on disk
        // by the time this fires, so a dismissal is itself the confirmation.
        .onChange(of: model.written) { _, written in
            guard let written else { return }
            onDone(written)
        }
    }

    /// The field's UI-test handle.
    public static let fieldIdentifier = "vault.capture.field"
}
