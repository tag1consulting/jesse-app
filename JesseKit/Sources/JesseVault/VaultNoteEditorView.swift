import SwiftUI

// THE EDITOR SCREEN: a text box, two buttons, and four things it has to ask.
//
// Every decision worth arguing about is in `VaultNoteEditorModel` and asserted there. What
// is left here is presentation and the one piece of plumbing a model cannot own: telling
// the model the scene went into the background, which is where the unsaved text is kept.

public struct VaultNoteEditorView: View {
    @State private var model: VaultNoteEditorModel
    /// Bumped whenever the text is replaced UNDER the person (Reload, a restored stash) so
    /// the text view knows to drop an undo stack that no longer describes its document.
    @State private var resetToken = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Told after a save so the reader behind this screen reloads rather than showing what
    /// it read before the edit.
    private let onSaved: () -> Void

    public init(path: String,
                model: VaultNoteEditorModel? = nil,
                onSaved: @escaping () -> Void = {}) {
        _model = State(initialValue: model ?? VaultNoteEditorModel(path: path))
        self.onSaved = onSaved
    }

    public var body: some View {
        content
            .navigationTitle(VaultWikiLink.basename(model.path))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if model.cancel() { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save()
                            if model.didSave {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task { await model.load() }
            // BOTH events, because only one of them is guaranteed. `.background` is what
            // iOS sends before it may terminate the app; `onDisappear` covers the editor
            // being popped by something other than a button.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.stashIfNeeded() }
            }
            .onDisappear { model.stashIfNeeded() }
            .alert("This note changed on disk while you were editing.",
                   isPresented: isPresenting(.conflict)) {
                Button("Reload") {
                    Task {
                        await model.reloadFromDisk()
                        resetToken &+= 1
                    }
                }
                Button("Overwrite", role: .destructive) { model.requestOverwrite() }
                Button("Keep editing", role: .cancel) { model.dismissPrompt() }
            } message: {
                Text("Reload takes the version on disk and discards what you typed. Overwrite keeps what you typed and replaces what is there now.")
            }
            .alert("Overwrite the newer version?",
                   isPresented: isPresenting(.confirmOverwrite)) {
                Button("Overwrite", role: .destructive) {
                    Task {
                        await model.overwrite()
                        if model.didSave {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) { model.dismissPrompt() }
            } message: {
                Text("Whatever was written to this note since you opened it will be gone.")
            }
            .alert("Discard your changes?", isPresented: isPresenting(.confirmDiscard)) {
                Button("Discard", role: .destructive) {
                    model.confirmDiscard()
                    dismiss()
                }
                Button("Keep editing", role: .cancel) { model.dismissPrompt() }
            }
            .alert("Restore unsaved edit?", isPresented: isPresentingRestore) {
                Button("Restore") {
                    if case .restore(let entry) = model.prompt {
                        model.restore(entry)
                        resetToken &+= 1
                    }
                }
                Button("Discard", role: .destructive) { model.discardStash() }
            } message: {
                if case .restore(let entry) = model.prompt {
                    Text("This note was left with changes that were never saved. \(entry.age).")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let why):
            caption(why, symbol: "lock")
        case .failed(let why):
            caption(why, symbol: "exclamationmark.triangle")
        case .editing:
            VStack(spacing: 0) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                VaultPlainTextEditor(text: $model.text, resetToken: resetToken)
            }
        }
    }

    private func caption(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A `Bool` binding onto "the model is asking exactly this".
    ///
    /// Setting it false has to go through `dismissPrompt`, not just drop the value:
    /// SwiftUI writes `false` back whenever an alert dismisses for any reason, and a
    /// binding that ignored that would leave the model believing it is still asking.
    private func isPresenting(_ prompt: VaultNoteEditorModel.Prompt) -> Binding<Bool> {
        Binding(get: { model.prompt == prompt },
                set: { if !$0, model.prompt == prompt { model.dismissPrompt() } })
    }

    /// `.restore` carries a payload, so it cannot be compared to a constant case.
    private var isPresentingRestore: Binding<Bool> {
        Binding(get: {
            if case .restore = model.prompt { return true }
            return false
        }, set: { presenting in
            if !presenting, case .restore = model.prompt { model.dismissPrompt() }
        })
    }
}
