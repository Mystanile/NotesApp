import XCTest
import SwiftUI
import SwiftData
import UIKit
import LocalAuthentication
import VisionKit
import Compression
import notify
@testable import Mystnotes

/// Simulator probes for the PLAN.md items "Owed on the iPad before M1
/// exits" that need the system rather than the Pencil: Face ID, the
/// document camera, a backup folder, covers in dark mode, and the drawing
/// toolbar's photo button (Oct 10, [not tested]).
///
/// The simulator has no Pencil, no camera and here no window you can
/// click, and public API can't make a touch. So these drive what the
/// gestures drive: the real `LAContext`, the real menus, accessibility
/// activation of the real buttons, the real bookmark. Each test says what
/// that can't show. Pictures go to `/tmp/mystnotes-probes/`
/// folder (or the test host's tmp if the host path can't be written).
@MainActor
final class SimProbeSystemTests: XCTestCase {
    /// Hosted screens with `@Query` share one container for the life of the
    /// process (CLAUDE.md gotcha).
    @MainActor private static var container: ModelContainer?

    // MARK: - Note lock with Face ID

    /// PLAN.md: "Note lock with Face ID". `NotebookLockTests` stands in for
    /// `authenticate`; this runs the real `LAContext` path
    /// (`NotebookLock.deviceOwner` / `deviceCanAuthenticate`) with the
    /// simulator's Face ID, driven by the darwin notifications BiometricKit
    /// listens to, posted from inside the test process:
    /// 1. enrolled, a matching face: `LockedNotebookGate` opens the notebook;
    /// 2. enrolled, a face that doesn't match: unlock never says yes, and
    ///    nothing opens;
    /// 3. not enrolled: with no passcode either, locking is refused and a
    ///    notebook locked elsewhere stays shut, answered at once, no prompt.
    ///
    /// Whether the notifications reach the simulator's biometrics from the
    /// app's sandbox is unverified - the `[faceid]` lines say what happened,
    /// and the test skips (after running step 3) if enrollment never took.
    ///
    /// Can't show: a real face, the TrueDepth camera, the passcode fallback
    /// (nothing can type it), or the first-use "Allow Face ID?" alert -
    /// if the system shows it, nothing here can tap it and step 1 times out.
    /// A non-match leaves the system's "Try Again" sheet up; that wait is
    /// reported, not failed, and un-enrolling is used to end it.
    func testFaceID_realLAContext_matchOpens_nonMatchRefuses_noEnrollmentRefusesCalmly() async throws {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription"),
                        "no NSFaceIDUsageDescription: on a device evaluatePolicy with Face ID crashes the app")

        let start = Date()
        func t() -> String { String(format: "t+%.1fs", Date().timeIntervalSince(start)) }
        let original = Self.enrollmentState()
        defer { Self.setEnrolled(original == 1); print("[faceid] \(t()) done, enrollment put back to \(original.map { "\($0)" } ?? "unknown")") }
        let lock = NotebookLock.shared
        let saved = (lock.authenticate, lock.canAuthenticate)
        lock.authenticate = NotebookLock.deviceOwner
        lock.canAuthenticate = NotebookLock.deviceCanAuthenticate
        defer { (lock.authenticate, lock.canAuthenticate) = saved; lock.relockAll() }

        // 1. Enrolled, matching face, through the real gate.
        let status = Self.setEnrolled(true)
        let enrolled = try await waitFor(4) { Self.biometricsAvailable() ? true : nil } ?? false
        print("[faceid] \(t()) enrollment set from inside the test: notify status \(status), took effect: \(enrolled). \(Self.policyReport())")

        var pending: Answer?
        if enrolled {
            let notebook = Notebook(title: "Diary")
            notebook.isLocked = true
            var shown = false
            let window = try makeWindow(CGSize(width: 500, height: 500))
            window.rootViewController = UIHostingController(rootView:
                LockedNotebookGate(notebook: notebook) { Color.red.onAppear { shown = true } })
            window.makeKeyAndVisible()
            // The gate asks in its `.task`; the face arrives once the sheet is up.
            let posted = Date()
            Self.post("com.apple.BiometricKit_Sim.pearl.match", after: 1.5)
            Self.post("com.apple.BiometricKit_Sim.pearl.match", after: 3.5)
            _ = try await waitFor(10) { shown ? true : nil }
            // Step 2 must not start until the spare match at 3.5 s has gone
            // by - otherwise it answers step 2's prompt (run 1 of this probe).
            let spare = 4.5 - Date().timeIntervalSince(posted)
            if spare > 0 { try await Task.sleep(for: .seconds(spare)) }
            savePNG(render(window), "faceid-match")
            window.rootViewController = nil
            window.isHidden = true
            print("[faceid] \(t()) matching face: notebook shown \(shown)")
            XCTAssertTrue(shown, "Face ID enrolled and a matching face posted, but the gate never opened the notebook "
                          + "within 10 s (if the system showed its first-use Face ID alert, nothing here can tap it)")
            XCTAssertEqual(lock.isOpen(notebook), shown)

            // 2. Enrolled, a face that doesn't match.
            let other = NotebookLock()
            let diary = Notebook(title: "Diary 2")
            diary.isLocked = true
            let answer = Answer()
            Task { answer.value = await other.unlock(diary) }
            Self.post("com.apple.BiometricKit_Sim.pearl.nomatch", after: 1.5)
            _ = try await waitFor(6) { answer.value }
            print("[faceid] \(t()) non-matching face: unlock answered \(answer.value.map { "\($0)" } ?? "nothing yet (system sheet still up)")")
            XCTAssertNotEqual(answer.value, true, "a face that doesn't match opened a locked notebook")
            XCTAssertFalse(other.isOpen(diary), "a face that doesn't match opened a locked notebook")
            if answer.value == nil {
                pending = answer
                // The gate's body calls `canAuthenticate()` on the main thread;
                // does it block while another evaluation's sheet is up?
                let before = Date()
                let can = NotebookLock.deviceCanAuthenticate()
                print(String(format: "[faceid] %@ canAuthenticate() on the main thread with a prompt pending: %@ in %.2f s",
                             t(), "\(can)", Date().timeIntervalSince(before)))
            }
        }

        // 3. Not enrolled.
        Self.setEnrolled(false)
        _ = try await waitFor(4) { Self.biometricsAvailable() ? nil : true }
        if let pending {
            _ = try await waitFor(3) { pending.value }
            print("[faceid] \(t()) after un-enrolling, the waiting non-match unlock answered \(pending.value.map { "\($0)" } ?? "nothing")")
            XCTAssertNotEqual(pending.value, true, "a face that doesn't match opened a locked notebook")
        }
        let canAuthenticate = NotebookLock.deviceCanAuthenticate()
        print("[faceid] \(t()) not enrolled: \(Self.policyReport())")

        let fresh = NotebookLock()
        let plain = Notebook(title: "Plain")
        let lockedIt = await fresh.setLocked(true, for: plain)
        print("[faceid] \(t()) not enrolled: setLocked answered \(lockedIt)")
        let elsewhere = Notebook(title: "Locked elsewhere")
        elsewhere.isLocked = true
        let answer = Answer()
        Task { answer.value = await fresh.unlock(elsewhere) }
        _ = try await waitFor(canAuthenticate ? 4 : 2) { answer.value }
        if canAuthenticate {
            // The simulator says it has a passcode: the system asks for it.
            print("[faceid] \(t()) not enrolled, but deviceOwnerAuthentication is available (passcode?) - unlock answered \(answer.value.map { "\($0)" } ?? "nothing (passcode sheet up)")")
            XCTAssertTrue(lockedIt, "the device can authenticate, so locking must be allowed")
            XCTAssertNotEqual(answer.value, true, "a locked notebook opened with nobody authenticating")
        } else {
            XCTAssertFalse(lockedIt, "no Face ID and no passcode: locking must be refused (nothing could unlock it)")
            XCTAssertNotEqual(plain.isLocked, true)
            XCTAssertEqual(answer.value, false, "no way to authenticate: unlock must answer no at once "
                           + "(nil means it waited \(2) s on something)")

            var shown = false
            let window = try makeWindow(CGSize(width: 500, height: 500))
            window.rootViewController = UIHostingController(rootView:
                LockedNotebookGate(notebook: elsewhere) { Color.red.onAppear { shown = true } })
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            savePNG(render(window), "faceid-no-passcode")
            window.rootViewController = nil
            window.isHidden = true
            XCTAssertFalse(shown, "the gate showed a locked notebook on a device that can't authenticate")
        }

        if !enrolled {
            throw XCTSkip("Face ID enrollment set from inside the test process never reached the simulator's "
                          + "biometrics (notify status \(status)); steps 1-2 didn't run. Enroll from the host "
                          + "(`xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` "
                          + "then `-p`) and post the match from the host instead.")
        }
    }

    // MARK: - Scanning

    /// PLAN.md: "Scanning with the real camera". `DocumentScannerView.isAvailable`
    /// is VisionKit's own answer. (The iOS 26.5 simulator says yes, and
    /// reports a camera; run 1 of this probe assumed no.) The one place that
    /// offers Scan is the notebook's Insert menu (`MystNotesDetailView`; a
    /// grep for `DocumentScannerView` finds no other). This opens that menu
    /// through accessibility, checks Scan Document is offered exactly when
    /// VisionKit supports it, and when it is, chooses it: the app's
    /// `.fullScreenCover` must present VisionKit's document camera.
    /// Pictures: `scan-menu.png`, `scan-camera.png`.
    ///
    /// Can't show: a scan of real paper, edge detection, or the
    /// scan-to-pages import after it (`ScanTests` covers the PDF). Skips if
    /// the menu can't be opened or read through accessibility.
    func testScan_isOfferedExactlyWhereSupported_andPresentsTheDocumentCamera() async throws {
        XCTAssertEqual(DocumentScannerView.isAvailable, VNDocumentCameraViewController.isSupported)
        print("[scan] VNDocumentCameraViewController.isSupported \(VNDocumentCameraViewController.isSupported), "
              + "camera \(UIImagePickerController.isSourceTypeAvailable(.camera))")

        let window = try await hostNotebook()
        defer {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.rootViewController = nil
            window.isHidden = true
        }
        savePNG(render(window), "scan-notebook")
        guard let (items, labels) = try await openMenu("Insert", in: window) else {
            throw XCTSkip("no accessibility element labelled Insert; labels: \(axElements(in: window).compactMap(\.accessibilityLabel))")
        }
        print("[scan] after opening Insert: \(labels)")
        guard labels.contains("From Photos") else {
            throw XCTSkip("activating Insert didn't show its items through accessibility; labels: \(labels)")
        }
        guard DocumentScannerView.isAvailable else {
            XCTAssertFalse(labels.contains("Scan Document"),
                           "the Insert menu offers Scan Document although the document camera is unsupported")
            return
        }
        let scan = try XCTUnwrap(menuRow("Scan Document", in: items),
                                 "VisionKit supports the document camera, but the Insert menu doesn't offer Scan Document")
        savePNG(render(window), "scan-menu")
        chooseRow(scan)
        try await Task.sleep(for: .seconds(3))
        savePNG(render(window), "scan-camera")
        let presented = presentedClassNames(in: window)
        print("[scan] presented after Scan Document: \(presented)")
        if presented.contains(where: { $0.contains("ContextMenu") }) {
            throw XCTSkip("Scan Document is offered, but the probe couldn't choose it: the menu is still up "
                          + "(\(presented)) - nothing reached the menu's action, so the camera half is unchecked")
        }
        XCTAssertTrue(presented.contains { $0.contains("VNDocumentCamera") },
                      "Scan Document didn't present VisionKit's document camera: \(presented)")
    }

    // MARK: - Backup folder

    /// PLAN.md: "A backup to a real Dropbox or Drive folder" - no file
    /// provider here. Instead: the path the Settings button takes once the
    /// picker returns a folder. `Backup.setFolder` stores a bookmark, it
    /// resolves to that folder, `Backup.run` (detached, as Settings runs
    /// it) resolves it again and writes that weekday's zip into the folder,
    /// and the zip, unzipped and chosen as a sync folder, restores the
    /// notebook with its ink on a fresh device. Then the folder is deleted
    /// under the bookmark, the way a user might in Dropbox: the next run
    /// must fail, not report a backup that didn't happen. `BackupTests`
    /// covers staging and the weekday names; this covers the bookmark.
    ///
    /// Payloads come from the app's own Documents (`FileStore`), so the
    /// probe puts its two ink files there and removes them after; the
    /// bookmark keys are put back as they were.
    ///
    /// Can't show: the folder picker, a security-scoped URL from a file
    /// provider (a folder in the sandbox isn't scoped:
    /// `startAccessingSecurityScopedResource` is false here), a provider
    /// that evicts or uploads lazily, or the scheduled run two minutes
    /// after launch.
    func testBackup_toAChosenFolder_resolvesItsBookmark_writesTheZip_andRestores() async throws {
        let defaults = UserDefaults.standard
        let keys = ["backupFolderBookmark", "backupFolderName", "backupLastRun"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let fm = FileManager.default
        let harness = try SyncTestHarness()
        var planted: [URL] = []
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            planted.forEach { try? fm.removeItem(at: $0) }
            try? fm.removeItem(at: harness.root)
        }

        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Thermo", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("backup probe \(UUID().uuidString)".utf8)
        try ipad.edit(page: pages[1], ink: ink)
        for page in pages {
            let name = try XCTUnwrap(page.drawingFileRef)
            let target = FileStore.url(for: name)
            try fm.copyItem(at: ipad.filesDirectory.appendingPathComponent(name), to: target)
            planted.append(target)
        }

        let chosen = harness.root.appendingPathComponent("Dropbox/Notes Backup", isDirectory: true)
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        print("[backup] security scope on the chosen folder: \(chosen.startAccessingSecurityScopedResource())")
        try Backup.setFolder(chosen)
        XCTAssertEqual(Backup.displayName, "Notes Backup")
        let bookmark = try XCTUnwrap(defaults.data(forKey: "backupFolderBookmark"), "setFolder stored no bookmark")
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().standardizedFileURL.path,
                       chosen.resolvingSymlinksInPath().standardizedFileURL.path, "the bookmark resolves somewhere else")
        XCTAssertFalse(stale, "a fresh bookmark is already stale")

        let container = ipad.container
        let result = await Task.detached(priority: .userInitiated) { Result { try Backup.run(container: container) } }.value
        try result.get()
        XCTAssertNotNil(Backup.lastRun)
        let written = try fm.contentsOfDirectory(atPath: chosen.path)
        XCTAssertEqual(written.count, 1, "\(written)")
        let zipName = try XCTUnwrap(written.first)
        XCTAssertTrue(zipName.hasPrefix("Mystnotes Backup ") && zipName.hasSuffix(".zip"), zipName)

        let entries = try Self.unzip(chosen.appendingPathComponent(zipName), into: harness.syncFolder)
        print("[backup] \(zipName): \(entries.count) entries, e.g. \(entries.prefix(6))")
        let restored = try harness.makeDevice("New iPad")
        try restored.sync()
        let back = try XCTUnwrap(try restored.pages(ofNotebook: notebook.id), "the backup didn't restore the notebook")
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(restored.ink(forPageID: pages[1].id), ink, "the backup didn't restore the ink")

        // The folder deleted under the bookmark.
        try fm.removeItem(at: chosen)
        let gone = await Task.detached(priority: .userInitiated) { Result { try Backup.run(container: container) } }.value
        switch gone {
        case .success: XCTFail("a backup into a folder that no longer exists reported success")
        case .failure(let error): print("[backup] folder deleted: Settings would say \"\(error.localizedDescription)\"")
        }
    }

    // MARK: - Covers in dark mode

    /// PLAN.md: "Notebook covers in dark mode" (`c60306c` was checked in
    /// light only). Every cover style as the library grid draws it
    /// (`NotebookCellView` on the system background), in a real window in
    /// light and in dark. Measures the WCAG contrast of the cover's paper
    /// label text against the label, and of the name under the cover
    /// against the library background, and fails below 4.5:1. Pictures:
    /// `covers-light.png`, `covers-dark.png`.
    ///
    /// Can't show: how it looks on the iPad's screen, or with Increase
    /// Contrast / larger text. The label's position is taken from
    /// `NotebookCoverView`'s geometry at 150 pt wide; if that changes, the
    /// geometry check below says so instead of measuring the wrong pixels.
    func testCovers_titlesStayReadable_inLightAndDark() async throws {
        let styles = ["default", "sunset", "ocean", "forest", "mono", "berry"]
        let notebooks = styles.map { style -> Notebook in
            let notebook = Notebook(title: style == "default" ? "Calculus II — Lecture Notes" : style.capitalized)
            notebook.coverStyle = style
            return notebook
        }
        let cell: CGFloat = 150, gap: CGFloat = 24
        let size = CGSize(width: gap * 2 + cell * 6 + gap * 5, height: 330)
        var failures: [String] = []

        for mode in [UIUserInterfaceStyle.light, .dark] {
            let name = mode == .dark ? "dark" : "light"
            let root = HStack(alignment: .top, spacing: gap) {
                ForEach(notebooks, id: \.id) { NotebookCellView(notebook: $0).frame(width: cell) }
            }
            .padding(gap)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
            let host = UIHostingController(rootView: root)
            host.safeAreaRegions = []
            let window = try makeWindow(size)
            window.overrideUserInterfaceStyle = mode
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            let image = render(window)
            window.rootViewController = nil
            window.isHidden = true
            savePNG(image, "covers-\(name)")
            let pixels = try Pixels(image)

            for (i, style) in styles.enumerated() {
                let x0 = gap + CGFloat(i) * (cell + gap), y0 = gap
                // NotebookCoverView at 150 wide: spine 13.5, label at x 28.5,
                // y 28, padding 7.5 x 5.25, text 12.75 pt in up to two lines.
                let labelPaper = CGPoint(x: x0 + 31, y: y0 + 31)
                let label = pixels.contrast(in: CGRect(x: x0 + 36, y: y0 + 33, width: 92, height: 30), background: labelPaper)
                // The name under the cover, on the library background.
                let title = pixels.contrast(in: CGRect(x: x0, y: y0 + 208, width: cell, height: 18),
                                            background: CGPoint(x: x0 - gap / 2, y: y0 + 217))
                print(String(format: "[covers] %@ %@: label paper luminance %.2f, label %.1f:1, name %.1f:1",
                             name, style, pixels.luminance(at: labelPaper), label, title))
                if mode == .light, pixels.luminance(at: labelPaper) < 0.8 {
                    XCTFail("probe geometry: the point sampled as the \(style) label's paper isn't the paper (luminance "
                            + "\(pixels.luminance(at: labelPaper))) - NotebookCoverView's layout changed; fix the probe")
                }
                if label < 4.5 { failures.append(String(format: "%@ %@: cover label text %.1f:1", name, style, label)) }
                if title < 4.5 { failures.append(String(format: "%@ %@: name under the cover %.1f:1", name, style, title)) }
            }
        }
        XCTAssertTrue(failures.isEmpty, "unreadable cover titles (WCAG AA needs 4.5:1): \(failures)")
    }

    // MARK: - Photo button on the drawing toolbar

    /// PLAN.md M2: "A photo button on the drawing toolbar (`8e5c0bc`)",
    /// [not tested], no test of its own. The bar with the button is wider
    /// by one button than the bar with Images hidden in Settings; the
    /// button, activated through accessibility (no touches), calls
    /// `onAddImage` once; on a whiteboard it is disabled and does nothing.
    /// Skips the accessibility half if SwiftUI's tree isn't reachable.
    ///
    /// Can't show: a finger or Pencil tap, or the button's hit area.
    func testPhotoButton_isOnTheToolbar_callsItsAction_andIsOffOnAWhiteboard() async throws {
        let key = AppSettings.Keys.hiddenToolbarItems
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }

        var tapped = 0
        func bar(paged: Bool) -> DrawingToolbarView {
            DrawingToolbarView(style: .inline, toolState: .constant(DrawingToolState()), openPopover: .constant(nil),
                               canUndo: false, canRedo: false, isFillToolAvailable: paged, isTextBoxAvailable: paged,
                               containerSize: .zero, onUndo: {}, onRedo: {}, onAddTextBox: {}, onAddSticker: {},
                               onAddLink: {}, onAddImage: { tapped += 1 })
        }
        // Hiding Images in Settings leaves Photo out of the Insert menu.
        UserDefaults.standard.set("", forKey: key)

        let window = try makeWindow(CGSize(width: 700, height: 120))
        defer { window.rootViewController = nil; window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: bar(paged: true))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        savePNG(render(window), "photo-toolbar")
        guard let (items, labels) = try await openMenu("Insert", in: window), let button = photoButton(in: items) else {
            throw XCTSkip("no Photo row in the Insert menu through accessibility; labels: \(axElements(in: window).compactMap(\.accessibilityLabel))")
        }
        print("[photo] Insert menu rows: \(labels)")
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
        chooseRow(button)
        try await Task.sleep(for: .milliseconds(500))
        // The row is there and enabled (asserted above). Choosing it needs a
        // touch: neither accessibilityActivate nor the menu's own selection
        // delegate reaches a SwiftUI Menu row in the simulator (Oct 24).
        let fired = tapped

        window.rootViewController = UIHostingController(rootView: bar(paged: false))
        try await Task.sleep(for: .seconds(1))
        let boardMenu = try await openMenu("Insert", in: window)
        let onBoard = try XCTUnwrap(boardMenu, "the Insert menu is gone on a whiteboard")
        let boardPhoto = try XCTUnwrap(photoButton(in: onBoard.0), "Photo is missing from the Insert menu on a whiteboard")
        XCTAssertTrue(boardPhoto.accessibilityTraits.contains(.notEnabled), "Photo is enabled on a whiteboard, where pictures can't go")
        chooseRow(boardPhoto)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tapped, fired, "Photo did something on a whiteboard")
        if fired == 0 {
            throw XCTSkip("Photo is in the Insert menu, enabled on paged pages and disabled on a whiteboard (checked); choosing the row without a touch does nothing, so onAddImage is unchecked")
        }
    }

    /// PLAN.md M2: the photo button, in the open notebook: what it presents.
    /// Activates the toolbar's photo button in `NotebookDetailView` and
    /// expects the Photos picker (`.photosPicker`, PHPicker - no library
    /// permission needed), never a camera picker; the simulator has no
    /// camera and the button never asks for one. `photo-picker.png` is the
    /// window after (the picker is another process and may draw blank).
    ///
    /// Can't show: picking a photo (the picker runs out of process), or the
    /// image import after it (`PageArtworkTests` covers importing).
    func testPhotoButton_inTheNotebook_presentsThePhotosPicker() async throws {
        let window = try await hostNotebook()
        defer {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.rootViewController = nil
            window.isHidden = true
        }
        guard let (items, labels) = try await openMenu("Insert", in: window), let button = photoButton(in: items) else {
            throw XCTSkip("no Photo row in the notebook's Insert menu; labels: \(axElements(in: window).compactMap(\.accessibilityLabel))")
        }
        print("[photo] Insert menu rows: \(labels)")
        chooseRow(button)
        try await Task.sleep(for: .seconds(2))
        savePNG(render(window), "photo-picker")
        if presentedClassNames(in: window).allSatisfy({ $0.contains("ContextMenu") }) {
            throw XCTSkip("Photo is in the Insert menu; the probe can't choose a menu row without a touch, so the picker is unchecked")
        }
        let presented = presentedClassNames(in: window)
        print("[photo] presented: \(presented); camera available: \(UIImagePickerController.isSourceTypeAvailable(.camera))")
        XCTAssertTrue(presented.contains { $0.contains("PHPicker") }, "the photo button presented \(presented), not the Photos picker")
        XCTAssertFalse(presented.contains { $0.contains("UIImagePickerController") }, "the photo button presented a camera/image picker")
    }

    // MARK: - Helpers

    @MainActor private final class Answer { var value: Bool? }

    private func waitFor<T>(_ seconds: Double, _ value: () -> T?) async throws -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let v = value() { return v }
            try await Task.sleep(for: .milliseconds(100))
        }
        return value()
    }

    private func makeWindow(_ size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    /// A one-page notebook open in a real window, as the library opens it.
    private func hostNotebook() async throws -> UIWindow {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let notebook = Notebook(title: "Probe")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        notebook.pages = [page]
        try context.save()

        let window = try makeWindow(CGSize(width: 1180, height: 820))
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        return window
    }

    private func render(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func savePNG(_ image: UIImage, _ name: String) {
        guard let data = image.pngData() else { return }
        let host = URL(fileURLWithPath: "/tmp/mystnotes-probes", isDirectory: true)
        for folder in [host, FileManager.default.temporaryDirectory.appendingPathComponent("probes", isDirectory: true)] {
            let url = folder.appendingPathComponent("\(name).png")
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? data.write(to: url)) != nil {
                print("[shot] \(url.path)")
                return
            }
        }
    }

    /// Every accessibility element under `root`: SwiftUI's own tree and
    /// UIKit's views. Nothing here touches the screen.
    private func axElements(in root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func visit(_ element: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.isAccessibilityElement { found.append(element) }
            if let children = element.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach { visit($0, depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<count { if let child = element.accessibilityElement(at: i) as? NSObject { visit(child, depth + 1) } }
                }
            }
            if let view = element as? UIView { view.subviews.forEach { visit($0, depth + 1) } }
        }
        visit(root, 0)
        return found
    }

    /// The Photo row of the Insert menu (exactly "Photo": "From Photos"
    /// is the New Pages row).
    private func photoButton(in elements: [NSObject]) -> NSObject? {
        menuRow("Photo", in: elements)
    }

    /// A menu row by label: the copy that sits in a collection view cell
    /// (the menu lists each label twice; only the cell's selects).
    private func menuRow(_ label: String, in elements: [NSObject]) -> NSObject? {
        let matches = elements.filter { $0.accessibilityLabel == label }
        func inCell(_ element: NSObject) -> Bool {
            var view: Any? = element
            while let e = view, !(e is UIView) { view = (e as? UIAccessibilityElement)?.accessibilityContainer }
            var v = view as? UIView
            while let x = v, !(x is UICollectionViewCell) { v = x.superview }
            return v != nil
        }
        return matches.first(where: inCell) ?? matches.first
    }

    /// Opens the menu button with this label and returns every
    /// accessibility element in the scene afterwards, with their labels.
    /// Accessibility activation alone doesn't open a SwiftUI Menu; the
    /// control's primary action is what a tap runs. nil if there is no
    /// such button or no rows appeared.
    private func openMenu(_ label: String, in window: UIWindow) async throws -> ([NSObject], [String])? {
        guard let button = axElements(in: window).first(where: { $0.accessibilityLabel == label }) else { return nil }
        var control = button as? UIView
        while let view = control, !(view is UIControl) { control = view.superview }
        if let control = control as? UIControl { control.performPrimaryAction() } else { _ = button.accessibilityActivate() }
        try await Task.sleep(for: .seconds(1.5))
        let items = (window.windowScene?.windows ?? [window]).flatMap { axElements(in: $0) }
        let labels = items.compactMap(\.accessibilityLabel)
        return (items, labels)
    }

    /// A tap on a menu row is the menu's collection view selecting it;
    /// accessibility activation of the row did nothing.
    private func chooseRow(_ element: NSObject) {
        var view: Any? = element
        while let e = view, !(e is UIView) { view = (e as? UIAccessibilityElement)?.accessibilityContainer }
        var cell = view as? UIView
        while let v = cell, !(v is UICollectionViewCell) { cell = v.superview }
        var list = cell?.superview
        while let v = list, !(v is UICollectionView) { list = v.superview }
        let activated = element.accessibilityActivate()
        print("[menu] accessibilityActivate \(activated), cell \(cell.map { "\(type(of: $0))" } ?? "none")")
        if !activated, let cell = cell as? UICollectionViewCell, let list = list as? UICollectionView, let row = list.indexPath(for: cell) {
            list.delegate?.collectionView?(list, didSelectItemAt: row)
        }
    }

    private func presentedClassNames(in window: UIWindow) -> [String] {
        var names: [String] = []
        func add(_ controller: UIViewController) {
            names.append(String(describing: type(of: controller)))
            controller.children.forEach(add)
        }
        var next = window.rootViewController?.presentedViewController
        while let controller = next {
            add(controller)
            next = controller.presentedViewController
        }
        return names
    }

    // Face ID in the simulator: BiometricKit's darwin notifications.

    private nonisolated static let enrollmentKey = "com.apple.BiometricKit.enrollmentChanged"

    nonisolated private static func enrollmentState() -> UInt64? {
        var token: Int32 = 0
        guard notify_register_check(enrollmentKey, &token) == 0 else { return nil }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        return notify_get_state(token, &state) == 0 ? state : nil
    }

    /// Returns the notify status of setting the state (0 is OK).
    @discardableResult
    nonisolated private static func setEnrolled(_ enrolled: Bool) -> UInt32 {
        var token: Int32 = 0
        let registered = notify_register_check(enrollmentKey, &token)
        guard registered == 0 else { return registered }
        let status = notify_set_state(token, enrolled ? 1 : 0)
        notify_cancel(token)
        notify_post(enrollmentKey)
        return status
    }

    nonisolated private static func post(_ name: String, after seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { _ = notify_post(name) }
    }

    nonisolated private static func biometricsAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    nonisolated private static func policyReport() -> String {
        let context = LAContext()
        var biometricError: NSError?
        let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
        var ownerError: NSError?
        let owner = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &ownerError)
        return "biometrics \(biometrics) (error \(biometricError?.code ?? 0)), device owner \(owner) "
            + "(error \(ownerError?.code ?? 0)), biometry type \(context.biometryType.rawValue)"
    }

    // A backup zip, unzipped the way Files does: central directory, stored
    // or deflated entries. The top folder ("Mystnotes Backup/") is what you
    // would choose as the sync folder, so its contents go into `folder`.

    nonisolated private static func unzip(_ zip: URL, into folder: URL) throws -> [String] {
        let bytes = [UInt8](try Data(contentsOf: zip))
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let corrupt = CocoaError(.fileReadCorruptFile)
        var end = bytes.count - 22
        while end >= 0, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= 0 else { throw corrupt }

        var entries: [(name: String, method: Int, packed: Int, size: Int, local: Int)] = []
        var p = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard u32(p) == 0x0201_4b50 else { throw corrupt }
            let nameLength = u16(p + 28)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append((name: name, method: u16(p + 10), packed: u32(p + 20), size: u32(p + 24), local: u32(p + 42)))
            p += 46 + nameLength + u16(p + 30) + u16(p + 32)
        }
        let top = "Mystnotes Backup/"
        let dropTop = entries.allSatisfy { $0.name.hasPrefix(top) }
        let fm = FileManager.default
        for entry in entries {
            let relative = dropTop ? String(entry.name.dropFirst(top.count)) : entry.name
            guard !relative.isEmpty else { continue }
            let target = folder.appendingPathComponent(relative)
            if relative.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard entry.packed != 0xFFFF_FFFF, entry.size != 0xFFFF_FFFF else { throw corrupt } // no zip64 here
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let start = entry.local + 30 + u16(entry.local + 26) + u16(entry.local + 28)
            let packed = Array(bytes[start..<(start + entry.packed)])
            var data: [UInt8]
            switch entry.method {
            case 0:
                data = packed
            case 8:
                data = [UInt8](repeating: 0, count: entry.size)
                if entry.size > 0 {
                    let written = compression_decode_buffer(&data, entry.size, packed, packed.count, nil, COMPRESSION_ZLIB)
                    guard written == entry.size else { throw corrupt }
                }
            default:
                throw corrupt
            }
            try Data(data).write(to: target)
        }
        return entries.map(\.name)
    }
}

/// A rendered picture's pixels, for measuring contrast (WCAG 2 relative
/// luminance, sRGB).
private struct Pixels {
    let width: Int, height: Int, scale: CGFloat
    let rgba: [UInt8]

    init(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        width = cgImage.width
        height = cgImage.height
        scale = image.scale
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drew)
        rgba = buffer
    }

    private func luminance(x: Int, y: Int) -> Double {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgba[i]) + 0.7152 * channel(rgba[i + 1]) + 0.0722 * channel(rgba[i + 2])
    }

    func luminance(at point: CGPoint) -> Double {
        luminance(x: Int(point.x * scale), y: Int(point.y * scale))
    }

    /// Contrast between the background at `background` and the pixel in
    /// `rect` farthest from it - the text's darkest (or lightest) stroke.
    func contrast(in rect: CGRect, background: CGPoint) -> Double {
        let back = luminance(at: background)
        var far = back
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let l = luminance(x: x, y: y)
                if abs(l - back) > abs(far - back) { far = l }
            }
        }
        return (max(back, far) + 0.05) / (min(back, far) + 0.05)
    }
}
