import XCTest
@testable import JesseVault

// THE FOLDER LIST, as a fold over paths and nothing else. No disk, no index, no actor.

final class VaultFolderTreeTests: XCTestCase {

    func testANoteCountsTowardEveryFolderAboveIt() {
        let folders = VaultFolderTree.folders(fromPaths: ["Projects/drafts/archive/x.md"])

        XCTAssertEqual(folders.map(\.path),
                       ["Projects", "Projects/drafts", "Projects/drafts/archive"])
        XCTAssertEqual(folders.map(\.noteCount), [1, 1, 1],
                       "one note, counted once at every depth above it")
    }

    func testCountsAddUpAcrossSiblings() {
        let folders = VaultFolderTree.folders(fromPaths: [
            "Projects/drafts/one.md",
            "Projects/drafts/two.md",
            "Projects/Research/three.md",
        ])

        XCTAssertEqual(folders, [
            VaultFolderCount(path: "Projects", noteCount: 3),
            VaultFolderCount(path: "Projects/drafts", noteCount: 2),
            VaultFolderCount(path: "Projects/Research", noteCount: 1),
        ])
    }

    /// A note at the vault root is in no folder. There is no synthetic root row.
    func testANoteAtTheRootContributesNoFolder() {
        XCTAssertEqual(VaultFolderTree.folders(fromPaths: ["Today.md"]), [])
    }

    func testAnEmptyInputGivesAnEmptyOutput() {
        XCTAssertEqual(VaultFolderTree.folders(fromPaths: []), [])
    }

    /// THE PREFIX TRAP, stated at the pure layer: `Work` and `Workshop` are two folders,
    /// and one is a string prefix of the other. They must never be merged.
    func testAFolderWhoseNameIsAPrefixOfAnotherStaysItsOwnFolder() {
        let folders = VaultFolderTree.folders(fromPaths: ["Work/a.md", "Workshop/b.md"])

        XCTAssertEqual(folders, [
            VaultFolderCount(path: "Work", noteCount: 1),
            VaultFolderCount(path: "Workshop", noteCount: 1),
        ])
    }

    func testTheOrderIsCaseInsensitiveAndStableAcrossTwoCalls() {
        let paths = ["zebra/a.md", "Apple/b.md", "apple/c.md", "Banana/d.md"]

        let first = VaultFolderTree.folders(fromPaths: paths)
        let second = VaultFolderTree.folders(fromPaths: paths.reversed())

        XCTAssertEqual(first.map(\.path), ["Apple", "apple", "Banana", "zebra"],
                       "case insensitive first, then case sensitive to break the tie")
        XCTAssertEqual(first, second,
                       "the same paths in any order give the same list, every time")
    }
}
