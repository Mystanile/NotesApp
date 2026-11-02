import XCTest
@testable import Mystnotes

final class LibrarySelectionTests: XCTestCase {
    func testToggleNotebookAndFolder() {
        var s = LibrarySelection()
        let nb = UUID(), f = UUID()
        s.toggleNotebook(nb)
        s.toggleFolder(f)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s.containsNotebook(nb))
        XCTAssertTrue(s.containsFolder(f))
        s.toggleNotebook(nb)
        XCTAssertFalse(s.containsNotebook(nb))
        XCTAssertEqual(s.count, 1)
        s.clear()
        XCTAssertTrue(s.isEmpty)
    }

    func testSelectAllAndIsAll() {
        var s = LibrarySelection()
        let nbs = [UUID(), UUID()], fs = [UUID()]
        XCTAssertFalse(s.isAll(notebooks: [], folders: []))
        s.selectAll(notebooks: nbs, folders: fs)
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s.isAll(notebooks: nbs, folders: fs))
        s.toggleFolder(fs[0])
        XCTAssertFalse(s.isAll(notebooks: nbs, folders: fs))
    }

    func testFolderCannotMoveIntoItselfOrDescendant() {
        let a = UUID(), b = UUID(), c = UUID(), other = UUID()
        let parents = [b: a, c: b]   // a > b > c ; other at top
        let s = LibrarySelection()
        XCTAssertFalse(s.canMoveFolder(a, into: a, parents: parents))
        XCTAssertFalse(s.canMoveFolder(a, into: c, parents: parents))
        XCTAssertTrue(s.canMoveFolder(c, into: a, parents: parents))
        XCTAssertTrue(s.canMoveFolder(a, into: other, parents: parents))
        XCTAssertTrue(s.canMoveFolder(a, into: nil, parents: parents))
    }

    func testCyclicParentsTerminate() {
        let a = UUID(), b = UUID(), x = UUID()
        let parents = [a: b, b: a]
        XCTAssertFalse(LibrarySelection.isSelfOrDescendant(x, of: a, parents: parents))
    }

    func testDeleteSkipsItemsInsideTickedFolders() {
        let a = UUID(), b = UUID(), other = UUID()
        let inA = UUID(), inB = UUID(), loose = UUID()
        let parents = [b: a]
        var s = LibrarySelection()
        s.toggleFolder(a); s.toggleFolder(b); s.toggleFolder(other)
        s.toggleNotebook(inA); s.toggleNotebook(inB); s.toggleNotebook(loose)
        XCTAssertEqual(s.outermostFolderIDs(parents: parents), [a, other])
        let outside = s.notebookIDsOutsideSelectedFolders(notebookFolders: [inA: a, inB: b], parents: parents)
        XCTAssertEqual(outside, [loose])
    }

    func testDeleteTitle() {
        XCTAssertEqual(LibrarySelection.deleteTitle(count: 1), "Delete 1 item?")
        XCTAssertEqual(LibrarySelection.deleteTitle(count: 3), "Delete 3 items?")
    }
}
