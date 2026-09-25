import XCTest
import SwiftUI
import UIKit
@testable import Mystnotes

/// Note lock, with Face ID stood in for.
final class NotebookLockTests: XCTestCase {

    @MainActor
    func testLockedNotebook_opensOnlyAfterAuthenticating_andRelocksInTheBackground() async {
        let lock = NotebookLock()
        var answer = false
        var asked = 0
        lock.authenticate = { _ in asked += 1; return answer }
        lock.canAuthenticate = { true }
        let notebook = Notebook(title: "Diary")
        XCTAssertTrue(lock.isOpen(notebook), "unlocked notebooks are open")

        let locked = await lock.setLocked(true, for: notebook)
        XCTAssertTrue(locked)
        XCTAssertFalse(lock.isOpen(notebook))
        XCTAssertEqual(asked, 0, "locking asks nothing")

        let refused = await lock.unlock(notebook)
        XCTAssertFalse(refused)
        XCTAssertFalse(lock.isOpen(notebook))

        answer = true
        let opened = await lock.unlock(notebook)
        XCTAssertTrue(opened)
        XCTAssertTrue(lock.isOpen(notebook))
        _ = await lock.unlock(notebook)
        XCTAssertEqual(asked, 2, "an open notebook doesn't ask again")

        lock.relockAll()
        XCTAssertFalse(lock.isOpen(notebook), "back to locked after the app backgrounds")
    }

    @MainActor
    func testRemovingALock_needsAuthentication() async {
        let lock = NotebookLock()
        lock.canAuthenticate = { true }
        lock.authenticate = { _ in false }
        let notebook = Notebook(title: "Diary")
        notebook.isLocked = true
        let removed = await lock.setLocked(false, for: notebook)
        XCTAssertFalse(removed)
        XCTAssertEqual(notebook.isLocked, true)
    }

    @MainActor
    func testWithoutAPasscode_aNotebookCantBeLocked() async {
        let lock = NotebookLock()
        lock.canAuthenticate = { false }
        let notebook = Notebook(title: "Diary")
        let locked = await lock.setLocked(true, for: notebook)
        XCTAssertFalse(locked)
        XCTAssertNotEqual(notebook.isLocked, true)
    }

    /// The gate in a real window: refused, the notebook never appears;
    /// accepted, it does.
    @MainActor
    func testGate_showsTheNotebookOnlyOnceUnlocked() async throws {
        let lock = NotebookLock.shared
        let saved = (lock.authenticate, lock.canAuthenticate)
        defer { (lock.authenticate, lock.canAuthenticate) = saved; lock.relockAll() }
        lock.canAuthenticate = { true }

        for answer in [false, true] {
            lock.relockAll()
            lock.authenticate = { _ in answer }
            let notebook = Notebook(title: "Diary")
            notebook.isLocked = true
            var shown = false
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            window.rootViewController = UIHostingController(rootView:
                LockedNotebookGate(notebook: notebook) { Color.red.onAppear { shown = true } })
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            window.isHidden = true
            XCTAssertEqual(shown, answer, answer ? "unlocked, but the notebook didn't show" : "the notebook showed while locked")
        }
    }
}
