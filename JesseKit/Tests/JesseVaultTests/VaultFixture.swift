import Foundation
@testable import JesseVault

// A SMALL INVENTED VAULT on disk, for the tests that need real files.
//
// EVERY WORD OF IT IS MADE UP. This repository is public, so not one line of the real
// vault may appear in it — the notes below are about a pottery studio, a bicycle and a
// fictional supplier, and they are shaped like real notes (frontmatter, `##` sections,
// wiki links, task boxes) precisely because the shape is what the code under test reads.

enum VaultFixture {

    /// A temporary directory that is deleted when `cleanUp` is called.
    static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Write one note, creating its parent directories.
    @discardableResult
    static func write(_ text: String, to relativePath: String, in root: URL) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Give a file a known modification time, so a diff can be driven without sleeping.
    static func touch(_ relativePath: String, in root: URL, date: Date) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.path)
    }

    /// The standing corpus: five notes that link to each other, one duplicate basename in
    /// two folders (the ambiguous case), and one note inside a dot directory that must
    /// never be indexed.
    static func writeCorpus(in root: URL) {
        write("""
            ---
            title: The Kiln Rebuild
            tags: pottery, workshop
            ---

            # Kiln notes

            The old kiln's floor cracked in the spring firing.

            ## Bricks

            [[Suppliers/Terrasole]] quoted for forty soft bricks. The café tiles came from
            the same yard.

            ## Schedule

            - [ ] Order the bricks
            - [x] Measure the arch
            - Talk to [[People/Marta Ruggeri|Marta]] about the burner

            """, to: "Workshop/Kiln-Rebuild.md", in: root)

        write("""
            # Terrasole

            A brickyard outside Perugia. Ask for Alberto.

            ## Prices

            Soft brick, per pallet: quoted twice a year.
            """, to: "Suppliers/Terrasole.md", in: root)

        write("""
            # Marta Ruggeri

            Runs the burner workshop. Knows [[Workshop/Kiln-Rebuild]] inside out.
            """, to: "People/Marta Ruggeri.md", in: root)

        // The AMBIGUOUS pair: two notes with the same file name in different folders, so
        // `[[Overview]]` resolves to neither.
        write("# Workshop overview\n\nBenches, wheels, the slip bucket.\n",
              to: "Workshop/Overview.md", in: root)
        write("# Bicycle overview\n\nThe winter bike and its bottom bracket.\n",
              to: "Bicycle/Overview.md", in: root)

        // Never indexed: a dot directory is not notes.
        write("# Obsidian workspace\n\nnot a note\n",
              to: ".obsidian/workspace.md", in: root)
    }
}
