import SwiftUI

// THE EDITOR SCREEN: a text box, two buttons, five marks, and four things it has to ask.
//
// Every decision worth arguing about is in `VaultNoteEditorModel` and asserted there. What
// is left here is presentation and the one piece of plumbing a model cannot own: telling
// the model the scene went into the background, which is where the unsaved text is kept.
//
// THE BAR IS THE ONLY NEW SURFACE, and it draws no conclusions of its own: which mark a
// selection can carry, what its characters are and where the caret lands are all
// `VaultAnnotationMarkup`, which is pure and tested. This file decides where the five
// buttons sit and which of them is grey.
//
// WHERE THEY SIT, on iOS, is a `safeAreaInset` at the bottom rather than a UIKit
// `inputAccessoryView`, and the choice was made on two grounds. The bar reads SwiftUI
// state (the selection, and the note's own text) to decide what is enabled, so an
// accessory view would mean a hosting controller inside the representable and a second
// copy of the enabling rule to keep in step with this one. And an inset is subtracted from
// the editor ONCE: SwiftUI puts it above the keyboard's own safe area, so showing and
// hiding the keyboard moves the keyboard and not the bar, which is the layout jump the
// accessory route has to be tuned to avoid. On macOS there is no keyboard to sit above and
// the bar is a row over the editor, where a toolbar would be on any other Mac document.

public struct VaultNoteEditorView: View {
    @State private var model: VaultNoteEditorModel
    /// Bumped whenever the text is replaced UNDER the person (Reload, a restored stash) so
    /// the text view knows to drop an undo stack that no longer describes its document.
    @State private var resetToken = 0
    /// What is selected in the text view, in UTF-16 units, so the bar can say what a mark
    /// would wrap. Written by the editor on every selection change.
    @State private var selection = NSRange(location: 0, length: 0)
    /// The edit a button made, and the token that makes the text view apply it exactly
    /// once. Never applied by assigning `text`: see `VaultPlainTextEditor`.
    @State private var pendingEdit: VaultTextEdit?
    @State private var editToken = 0
    /// The mark being composed, which is what the one-field sheet is for, and the words
    /// typed into it.
    @State private var composing: VaultAnnotationForm?
    @State private var field = ""
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
                #if os(macOS)
                annotationBar
                Divider()
                #endif
                VaultPlainTextEditor(text: $model.text, resetToken: resetToken,
                                     selectedRange: $selection,
                                     pendingEdit: pendingEdit, editToken: editToken)
            }
            #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    annotationBar
                }
                .background(.bar)
            }
            #endif
            .sheet(item: $composing) { form in
                VaultAnnotationSheet(form: form, text: $field,
                                     words: VaultAnnotationMarkup.selected(selection,
                                                                          in: model.text),
                                     onCancel: { composing = nil },
                                     onApply: { typed in apply(form, field: typed) })
                #if os(macOS)
                    .frame(minWidth: 380, minHeight: 200)
                #endif
            }
        }
    }

    // MARK: - The bar

    /// Five marks, and one line saying why three of them are grey.
    ///
    /// Horizontally scrollable because five labelled buttons are wider than a phone in
    /// German and in Italian, and a bar that clipped its last button would hide the one
    /// mark (Comment) a reviewer reaches for most.
    private var annotationBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ALWAYS THE LINE, sometimes the words. The caption comes and goes with the
            // selection, and a bar that grew and shrank by one line every time somebody
            // selected a word would move the editor under their finger. Hidden rather than
            // absent, so the bar is one height.
            let caption = VaultAnnotationMarkup.caption(forSelection: selection,
                                                        in: model.text)
            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(caption == nil ? 0 : 1)
                .padding(.horizontal, 10)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(VaultAnnotationForm.allCases) { form in
                        Button { begin(form) } label: {
                            Label(form.label, systemImage: form.symbol)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(refusal(form) != nil)
                        .help(refusal(form) ?? form.sheetTitle)
                        .accessibilityIdentifier(Self.buttonIdentifier(form))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Why this form cannot act on what is selected, or nil.
    private func refusal(_ form: VaultAnnotationForm) -> String? {
        VaultAnnotationMarkup.refusal(forSelection: selection, in: model.text, form: form)
    }

    /// A button pressed. Delete applies at once, because the selection is the whole of it;
    /// the other four ask for their words first.
    private func begin(_ form: VaultAnnotationForm) {
        guard refusal(form) == nil else { return }
        guard form.asksForText else { return apply(form, field: "") }
        field = VaultAnnotationMarkup.prefill(form, selection: selection, in: model.text)
        composing = form
    }

    /// Hand the edit to the text view. The model's text comes back through the editor's own
    /// delegate, so the save path, the dirty flag and undo are all exactly what they were.
    private func apply(_ form: VaultAnnotationForm, field: String) {
        guard let edit = VaultAnnotationMarkup.edit(form, selection: selection,
                                                    in: model.text, field: field) else { return }
        pendingEdit = edit
        editToken &+= 1
        composing = nil
    }

    /// Each button's UI-test handle.
    public static func buttonIdentifier(_ form: VaultAnnotationForm) -> String {
        "vault.annotation." + form.rawValue
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


/// ONE FIELD FOR ONE MARK.
///
/// A view of its own rather than a builder on the editor, for the reason the capture sheet
/// is one: `@FocusState` belongs to the view that owns the field, and a focus binding
/// declared on the presenting screen does not reach across a sheet boundary. This sheet
/// exists to be typed into, and one that makes you tap before typing is one that gets used
/// less.
///
/// THE FIELD IS A BINDING, not a `@State` seeded from a parameter, and that distinction
/// cost a simulator run to find. `@State` takes its initial value the first time SwiftUI
/// builds a view's identity and IGNORES the parameter ever after, so a Replace sheet
/// opened after any earlier sheet came up holding the first one's words: the prefill (the
/// selected words, which are the whole point of Replace) silently did not arrive. The
/// editor owns the text being typed, this owns the field.
private struct VaultAnnotationSheet: View {
    let form: VaultAnnotationForm
    @Binding var text: String
    /// What the words the person marked are, when the form is about words already there.
    let words: String?
    let onCancel: () -> Void
    let onApply: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(form.fieldPrompt, text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                        .accessibilityIdentifier(VaultAnnotationSheet.fieldIdentifier)
                    if let words, !words.isEmpty, form.needsSelection {
                        Text(words)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(form.sheetTitle)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(form.sheetTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && !form.allowsEmptyText)
                }
            }
        }
        .onAppear { focused = true }
    }

    /// The field's UI-test handle.
    static let fieldIdentifier = "vault.annotation.field"
}
