import XCTest
import CoreGraphics
import PencilKit
@testable import Mystnotes

final class StudyPanelTests: XCTestCase {

    // MARK: Context

    func testContext_buildsPageBlocksInOrder() {
        let text = StudyContext.text(pages: [
            .init(number: 1, title: "Cells", typed: ["Mitochondria"], recognized: "powerhouse"),
            .init(number: 3, recognized: "Golgi"),
        ])
        XCTAssertEqual(text, "Page 1:\nCells\nMitochondria\npowerhouse\n\nPage 3:\nGolgi")
    }

    func testContext_unindexedHandwritingIsNoted_notOcrd() {
        let text = StudyContext.text(pages: [
            .init(number: 2, typed: ["Typed"], recognized: nil, handwritingIndexed: false),
            .init(number: 4, handwritingIndexed: false),
        ])
        XCTAssertEqual(text, "Page 2:\nTyped\n(handwriting not yet indexed)\n\nPage 4:\n(handwriting not yet indexed)")
    }

    func testContext_blankIndexedPagesAreLeftOut() {
        let pages: [StudyContext.Entry] = [.init(number: 1, recognized: "  \n"), .init(number: 2, typed: ["x"])]
        XCTAssertEqual(StudyContext.text(pages: pages), "Page 2:\nx")
        XCTAssertTrue(StudyContext.hasReadableText(pages))
    }

    func testContext_placeholderAloneIsNotReadable() {
        let pages: [StudyContext.Entry] = [.init(number: 1, handwritingIndexed: false)]
        XCTAssertFalse(StudyContext.hasReadableText(pages))
        XCTAssertEqual(StudyContext.text(pages: []), "")
    }

    func testSendSummary_namesScopeAndCount() {
        XCTAssertTrue(StudyContext.sendSummary(characterCount: 420, scope: .page).contains("420 characters"))
        XCTAssertTrue(StudyContext.sendSummary(characterCount: 420, scope: .page).contains("this page"))
        XCTAssertTrue(StudyContext.sendSummary(characterCount: 5, scope: .notebook).contains("this notebook"))
        let long = StudyContext.sendSummary(characterCount: StudyPrompts.contextLimit + 500, scope: .notebook)
        XCTAssertTrue(long.contains("\(StudyPrompts.contextLimit) of \(StudyPrompts.contextLimit + 500)"))
    }

    // MARK: Markdown

    func testStripMarkdown_removesSymbolsKeepsWords() {
        let md = "# Title\n\n**Bold** and *italic* and `code`.\n\n* one\n- two\n1. three\n\n[link](https://x.y) snake_case"
        XCTAssertEqual(StudyText.stripMarkdown(md),
                       "Title\n\nBold and italic and code.\n\n- one\n- two\n1. three\n\nlink snake_case")
    }

    func testStripMarkdown_dropsFencesAndQuotes() {
        XCTAssertEqual(StudyText.stripMarkdown("```swift\nlet x = 1\n```\n> quoted"), "let x = 1\n\nquoted")
    }

    func testForHandwriting_asciiPunctuation() {
        XCTAssertEqual(StudyText.forHandwriting("It\u{2019}s \u{201C}fine\u{201D} \u{2013} ok\u{2026}"), "It's \"fine\" - ok...")
    }

    func testCap_cutsAtWordBreakAndReports() {
        let text = Array(repeating: "word", count: 400).joined(separator: " ")
        let (capped, truncated) = StudyText.cap(text, limit: 100)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(capped.count, 100)
        XCTAssertTrue(capped.hasSuffix("word"))
        let (short, no) = StudyText.cap("hi", limit: 100)
        XCTAssertEqual(short, "hi")
        XCTAssertFalse(no)
    }

    // MARK: Quiz

    func testQuizText_questionAnswerPairs() {
        let items = [QuizItem(question: "What is **ATP**?", answer: "Energy"), QuizItem(question: "Q2", answer: "A2")]
        XCTAssertEqual(StudyText.quizText(items), "Q: What is ATP?\nA: Energy\n\nQ: Q2\nA: A2")
    }

    // MARK: Geometry

    func testPlacement_fullPageAtFit() {
        let page = CGRect(x: 0, y: 0, width: 780, height: 1040)
        let p = WriteOnPageGeometry.placement(visible: page, page: page, zoom: 1)
        XCTAssertEqual(p.origin, CGPoint(x: 24, y: 24))
        XCTAssertEqual(p.maxWidth, 732)
        XCTAssertEqual(p.xHeight, 9)
    }

    func testPlacement_zoomedInUsesVisibleCorner_andSmallerXHeight() {
        let page = CGRect(x: 0, y: 0, width: 780, height: 1040)
        let visible = WriteOnPageGeometry.visibleRect(viewSize: CGSize(width: 800, height: 600), zoom: 2,
                                                      offset: CGPoint(x: 400, y: 1000))
        XCTAssertEqual(visible, CGRect(x: 200, y: 500, width: 400, height: 300))
        let p = WriteOnPageGeometry.placement(visible: visible, page: page, zoom: 2)
        XCTAssertEqual(p.origin, CGPoint(x: 224, y: 524))
        XCTAssertEqual(p.maxWidth, 352)
        XCTAssertEqual(p.xHeight, 6)   // 4.5 clamped up
    }

    func testPlacement_zoomedOutGrowsXHeight_andClampsToPage() {
        let page = CGRect(x: 0, y: 0, width: 780, height: 1040)
        let visible = CGRect(x: -100, y: -50, width: 400, height: 600)   // letterboxed: partly off the page
        let p = WriteOnPageGeometry.placement(visible: visible, page: page, zoom: 0.5)
        XCTAssertEqual(p.origin, CGPoint(x: 24, y: 24))
        XCTAssertEqual(p.maxWidth, 252)
        XCTAssertEqual(p.xHeight, 18)
    }

    func testPlacement_barelyVisibleFallsBackToWholePage() {
        let page = CGRect(x: 0, y: 0, width: 780, height: 1040)
        let p = WriteOnPageGeometry.placement(visible: CGRect(x: 760, y: 1000, width: 400, height: 400), page: page, zoom: 1)
        XCTAssertEqual(p.origin, CGPoint(x: 24, y: 24))
        XCTAssertEqual(p.maxWidth, 732)
    }

    // MARK: Export

    func testAddHandwritingProfile_copiesWhenPresent_skipsWhenAbsent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("StudyPanelTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("profile.json")
        let root = dir.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        LibraryExport.addHandwritingProfile(from: source, to: root)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Handwriting").path))

        try Data("{}".utf8).write(to: source)
        LibraryExport.addHandwritingProfile(from: source, to: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Handwriting/profile.json")), Data("{}".utf8))
    }

    func testAddHandwritingProfile_neverOverwritesAnExistingFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("StudyPanelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("profile.json")
        let root = dir.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)

        let folder = root.appendingPathComponent("Handwriting", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("profile.json"))

        LibraryExport.addHandwritingProfile(from: source, to: root)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("profile.json")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("profile-1.json")), Data("new".utf8))
    }

    // MARK: Off the main thread

    nonisolated final class ThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var onMain = 0
        func record() { lock.lock(); calls += 1; if Thread.isMainThread { onMain += 1 }; lock.unlock() }
    }

    @MainActor
    func testHandwritingWriter_generate_runsOffTheMainThread() async {
        let probe = ThreadProbe()
        let request = HandwritingWriter.Request(
            text: "Hello", placement: .init(origin: CGPoint(x: 24, y: 24), maxWidth: 300, xHeight: 9),
            inkType: .pen, rgba: [0, 0, 0, 1], width: 3, seed: 7,
            onBuild: { probe.record() })

        _ = await HandwritingWriter.generate(request)

        XCTAssertEqual(probe.calls, 1, "the layout ran")
        XCTAssertEqual(probe.onMain, 0, "handwriting layout ran on the main thread")
    }
}
