import SwiftUI
import UIKit
import UniformTypeIdentifiers
import JesseVault

// THE ONE PIECE THAT CANNOT LIVE IN JesseKit: the iOS folder picker.
//
// `UIDocumentPickerViewController` is UIKit, and JesseVault is deliberately free of
// it (the same line JesseTodayDisplay holds). So the app target contributes the
// picker and nothing else: it hands the chosen URL straight to `VaultFolder.adopt`,
// which is where every decision about bookmarks is made.
//
// `forOpeningContentTypes: [.folder]` and ONLY `.folder`. A picker that also
// accepted files would let a mis-tap point the whole offline layer at a single note.
//
// `asCopy` is deliberately left at its default of false: a copy would be a snapshot
// in the app's container, which is the opposite of the point — the folder has to be
// Obsidian's own, so that what Obsidian syncs is what this reads.

struct VaultFolderPicker: UIViewControllerRepresentable {
    /// Called with the folder the user picked, on the main actor. Cancelling calls
    /// nothing at all.
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
