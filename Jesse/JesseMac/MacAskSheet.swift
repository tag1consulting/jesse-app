import SwiftUI
import JesseCore

/// The conversation an "Ask about this" opens, in a sheet sized like the Today tab's — one
/// window shape for "a conversation opened from a screen", not one per screen.
///
/// It began private to `MacHealthView` and moved here when the Ops screens gained the same
/// gesture: two shells of the same sheet is two window sizes and two Done buttons to keep
/// in step. Nothing in it knows which screen the ask came from.
struct MacAskSheet: View {
    let thread: JesseThread
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            MacThreadDetailView(thread: thread)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 620)
    }
}
