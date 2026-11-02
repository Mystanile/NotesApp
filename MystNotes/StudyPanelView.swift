import SwiftUI
import SwiftData
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
import PencilKit
#endif

// MARK: - Scope

/// What the Study panel reads: the page on screen, or the whole notebook.
nonisolated enum StudyScope: String, CaseIterable, Identifiable, Sendable {
    case page = "This Page"
    case notebook = "This Notebook"
    var id: String { rawValue }
}

// MARK: - Context (pure)

/// Builds the text the AI is given. Pure: the model layer turns pages into
/// `Entry` values, and everything else works on those.
///
/// Handwriting is never recognized here (invariant 10, and it would be slow):
/// only the cached OCR text is used. A page that was never indexed says so
/// instead of silently looking empty.
nonisolated enum StudyContext {
    static let notIndexedNote = "(handwriting not yet indexed)"

    struct Entry: Equatable, Sendable {
        var number: Int
        var title: String?
        var typed: [String]
        var recognized: String?
        var pdf: [String]
        /// True once OCR has run for the page (even if it found nothing).
        var handwritingIndexed: Bool

        init(number: Int, title: String? = nil, typed: [String] = [], recognized: String? = nil,
             pdf: [String] = [], handwritingIndexed: Bool = true) {
            self.number = number
            self.title = title
            self.typed = typed
            self.recognized = recognized
            self.pdf = pdf
            self.handwritingIndexed = handwritingIndexed
        }

        /// Text that is really on the page, not a placeholder.
        var parts: [String] {
            var out: [String] = []
            if let title, !title.trimmed.isEmpty { out.append(title.trimmed) }
            out.append(contentsOf: typed.map(\.trimmed).filter { !$0.isEmpty })
            if let recognized, !recognized.trimmed.isEmpty { out.append(recognized.trimmed) }
            out.append(contentsOf: pdf.map(\.trimmed).filter { !$0.isEmpty })
            return out
        }
    }

    /// "Page N:\n<text>" blocks, blank line between. A page with no text at
    /// all is left out, unless its handwriting has not been read yet, in
    /// which case it is listed with a note so the answer isn't misleading.
    static func text(pages: [Entry]) -> String {
        var blocks: [String] = []
        for entry in pages {
            var parts = entry.parts
            if !entry.handwritingIndexed { parts.append(notIndexedNote) }
            guard !parts.isEmpty else { continue }
            blocks.append("Page \(entry.number):\n" + parts.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Whether there is anything to send besides placeholders.
    static func hasReadableText(_ pages: [Entry]) -> Bool {
        pages.contains { !$0.parts.isEmpty }
    }

    /// The one line shown before the first send.
    static func sendSummary(characterCount: Int, scope: StudyScope) -> String {
        let what = scope == .page ? "this page" : "this notebook"
        let sent = min(characterCount, StudyPrompts.contextLimit)
        var line = "Sends \(sent) characters of text from \(what) to Featherless. Ink images are never sent."
        if characterCount > StudyPrompts.contextLimit {
            line = "Sends \(sent) of \(characterCount) characters of text from \(what) (the middle is left out) to Featherless. Ink images are never sent."
        }
        return line
    }

    /// Turns pages into entries. `numbers` are 1-based positions in the notebook.
    static func entries(for pages: [(number: Int, page: Page)],
                        documents: [UUID: [ImportedDocument]]) -> [Entry] {
        pages.map { number, page in
            let blocks = (page.textBlocks ?? []).sorted { ($0.frameY, $0.frameX) < ($1.frameY, $1.frameX) }
            var pdf: [String] = []
            for doc in documents[page.id] ?? [] where doc.sourceType == "pdf" && !doc.fileRef.isEmpty {
                if let t = SearchIndex.pdfPageText(fileRef: doc.fileRef, pageIndex: doc.pdfPageIndex) { pdf.append(t) }
            }
            let recognized = page.recognizedTextCache
            let indexed = page.ocrUpdatedAt != nil || !(recognized ?? "").trimmed.isEmpty
            return Entry(number: number, title: page.title, typed: blocks.map(\.content),
                         recognized: recognized, pdf: pdf, handwritingIndexed: indexed)
        }
    }
}

private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Text shaping (pure)

nonisolated enum StudyText {
    /// Most characters one Write on Page puts down.
    static let writeLimit = 1_200

    /// Markdown to the plain words, for reading aloud and for handwriting.
    static func stripMarkdown(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("(?m)^[ \\t]*```.*$", "")                       // code fences
        sub("(?m)^[ \\t]{0,3}#{1,6}[ \\t]*", "")               // headings
        sub("(?m)^[ \\t]*>[ \\t]?", "")                        // quotes
        sub("(?m)^([ \\t]*)[-*+\u{2022}][ \\t]+", "$1- ")      // bullets, before emphasis
        sub("\\[([^\\]]+)\\]\\([^)]*\\)", "$1")          // links
        sub("\\*{1,3}([^*\\n]+)\\*{1,3}", "$1")          // bold / italic
        sub("__([^_\\n]+)__", "$1")
        sub("(?<![A-Za-z0-9])_([^_\\n]+)_(?![A-Za-z0-9])", "$1")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        sub("[ \\t]+\\n", "\n")
        sub("\\n{3,}", "\n\n")
        return s.trimmed
    }

    /// Plain text with the punctuation the handwriting set has: curly quotes,
    /// dashes and ellipses become their ASCII forms.
    static func forHandwriting(_ text: String) -> String {
        var s = stripMarkdown(text)
        let map: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2026}", "..."), ("\u{00A0}", " "),
            ("\u{00D7}", "x"), ("\u{2022}", "-")
        ]
        for (from, to) in map { s = s.replacingOccurrences(of: from, with: to) }
        return s
    }

    /// "Q: ...\nA: ..." pairs, a blank line between.
    static func quizText(_ items: [QuizItem]) -> String {
        items.map { "Q: \(stripMarkdown($0.question))\nA: \(stripMarkdown($0.answer))" }
            .joined(separator: "\n\n")
    }

    /// At most `limit` characters, cut at a line or word break where there
    /// is one. `truncated` says something was left off.
    static func cap(_ text: String, limit: Int = writeLimit) -> (text: String, truncated: Bool) {
        let t = text.trimmed
        guard t.count > limit else { return (t, false) }
        let head = String(t.prefix(limit))
        if let cut = head.lastIndex(where: { $0 == "\n" || $0 == " " }), head.distance(from: head.startIndex, to: cut) > limit / 2 {
            return (String(head[..<cut]).trimmed, true)
        }
        return (head.trimmed, true)
    }

    /// Bullets as dots for on-screen display; the rest is left to Markdown.
    static func displayMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^([ \\t]*)[-*+][ \\t]+", with: "$1\u{2022} ", options: .regularExpression)
    }

    static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: displayMarkdown(text), options: options)) ?? AttributedString(text)
    }
}

// MARK: - Write on Page geometry (pure)

nonisolated enum WriteOnPageGeometry {
    struct Placement: Equatable, Sendable {
        var origin: CGPoint
        var maxWidth: CGFloat
        var xHeight: CGFloat
    }

    static let margin: CGFloat = 24
    /// Apparent x-height, in screen points, the writing aims for.
    static let targetXHeight: CGFloat = 9
    static let xHeightRange: ClosedRange<CGFloat> = 6...24

    /// The part of the page space the canvas is showing.
    static func visibleRect(viewSize: CGSize, zoom: CGFloat, offset: CGPoint) -> CGRect {
        let z = max(zoom, 0.0001)
        return CGRect(x: offset.x / z, y: offset.y / z, width: viewSize.width / z, height: viewSize.height / z)
    }

    /// Top-left of the visible part of the page plus a margin, as wide as
    /// the visible part less a margin each side. Falls back to the whole
    /// page when almost none of it is visible. The x-height keeps its size
    /// on screen: 9 pt at 100%, larger in page points when zoomed out.
    static func placement(visible: CGRect, page: CGRect, zoom: CGFloat) -> Placement {
        var area = visible.intersection(page)
        if area.isNull || area.width < 120 || area.height < 60 { area = page }
        let m = min(margin, area.width / 6)
        let xh = min(max(targetXHeight / max(zoom, 0.1), xHeightRange.lowerBound), xHeightRange.upperBound)
        return Placement(origin: CGPoint(x: area.minX + m, y: area.minY + m),
                         maxWidth: max(area.width - 2 * m, xh * 4),
                         xHeight: xh)
    }
}

enum StudyWriteOutcome: Equatable {
    case written(truncated: Bool, runsPastPage: Bool)
    case noPage, pageChanged, empty

    var message: String {
        switch self {
        case .written(let truncated, let past):
            var s = "Written on the page. Undo takes it back."
            if truncated { s += " Only the first \(StudyText.writeLimit) characters were written." }
            if past { s += " It runs past the bottom of the page." }
            return s
        case .noPage: return "Wait for the page to finish loading, then try again."
        case .pageChanged: return "The page changed before the writing was done. Nothing was added."
        case .empty: return "There was nothing to write."
        }
    }
}

#if canImport(UIKit)

// MARK: - Stroke generation (off the main thread)

/// Lays text out as handwriting strokes on a background thread. Capture-free:
/// everything crosses in as values (invariant 10; see `DrawingStore.saveDetached`).
nonisolated enum HandwritingWriter {
    struct Request: Sendable {
        var text: String
        var placement: WriteOnPageGeometry.Placement
        var inkType: PKInkingTool.InkType
        var rgba: [Double]
        var width: CGFloat
        var seed: UInt64
    }

    struct Output: @unchecked Sendable {
        var strokes: [PKStroke]
        var maxY: CGFloat
    }

    static func generate(_ request: Request) async -> Output {
        await Task.detached(priority: .userInitiated) { build(request) }.value
    }

    static func build(_ r: Request) -> Output {
        let c = r.rgba
        let color = UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
        let strokes = HandwritingSynth.layout(
            text: r.text, profile: HandwritingProfileStore.load(), origin: r.placement.origin,
            maxWidth: r.placement.maxWidth, xHeight: r.placement.xHeight,
            ink: PKInk(r.inkType, color: color), width: r.width, baseDate: Date(), seed: r.seed)
        return Output(strokes: strokes, maxY: strokes.map { $0.renderBounds.maxY }.max() ?? 0)
    }
}

// MARK: - Model

@Observable
final class StudyPanelModel {
    enum Action { case summarize, explain, quiz, ask(String) }
    enum Phase {
        case idle
        case loading
        case answer(String)
        case quiz([QuizItem])
        case failed(AIError)
    }

    var phase: Phase = .idle
    var hasSent = false
    var quizIndex = 0
    var quizFlipped = false
    var quizResults: [Int: Bool] = [:]
    private var task: Task<Void, Never>?

    func start(_ action: Action, notes: String) {
        cancel()
        phase = .loading
        hasSent = true
        let modelName = AppSettings.aiModel
        task = Task { [weak self] in
            // The request is awaited on AIClient's own (nonisolated) async
            // call; only the state changes below happen on the main actor.
            do {
                let client = AIClient(model: modelName)
                switch action {
                case .quiz:
                    let p = StudyPrompts.quiz(notes: notes)
                    let reply = try await client.complete(system: p.system, user: p.user, maxTokens: 1_200)
                    let items = StudyPrompts.parseQuiz(reply)
                    guard !items.isEmpty else { throw AIError.decoding }
                    try Task.checkCancellation()
                    self?.quizIndex = 0; self?.quizFlipped = false; self?.quizResults = [:]
                    self?.phase = .quiz(items)
                default:
                    let p: (system: String, user: String)
                    switch action {
                    case .summarize: p = StudyPrompts.summarize(notes: notes)
                    case .explain: p = StudyPrompts.explain(notes: notes)
                    case .ask(let q): p = StudyPrompts.ask(question: q, notes: notes)
                    case .quiz: p = StudyPrompts.quiz(notes: notes)
                    }
                    let reply = try await client.complete(system: p.system, user: p.user)
                    try Task.checkCancellation()
                    self?.phase = .answer(reply)
                }
            } catch is CancellationError {
                self?.phase = .idle
            } catch let error as AIError {
                self?.phase = .failed(error)
            } catch {
                self?.phase = .failed(.other("The request couldn't be completed."))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .loading = phase { phase = .idle }
    }

    func mark(_ knew: Bool, count: Int) {
        quizResults[quizIndex] = knew
        if quizIndex + 1 < count { quizIndex += 1; quizFlipped = false }
        else { quizFlipped = false; quizIndex = count }   // past the end: summary
    }

    var knewCount: Int { quizResults.values.filter { $0 }.count }
}

// MARK: - View

struct StudyPanelView: View {
    let pageID: UUID?
    let canWrite: Bool
    let entries: (StudyScope) -> [StudyContext.Entry]
    let onWrite: (String) async -> StudyWriteOutcome
    let onClose: () -> Void

    @State private var model = StudyPanelModel()
    @State private var player = ReadAloudPlayer()
    @State private var scope: StudyScope = .page
    @State private var contextCount = 0
    @State private var contextReadable = true
    @State private var hasKey = Keychain.get(Keychain.Account.featherless) != nil
    @State private var hasProfile = FileManager.default.fileExists(atPath: HandwritingProfileStore.fileURL.path)
    @State private var asking = false
    @State private var question = ""
    @State private var status: String?
    @State private var writing = false
    @State private var showingSettings = false
    @State private var showingCapture = false

    private struct ContextKey: Equatable { var scope: StudyScope; var pageID: UUID? }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                if !hasKey { noKeyCard }
                Picker("Scope", selection: $scope) {
                    ForEach(StudyScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if case .idle = model.phase, !model.hasSent { sendNote }
                tiles
                if asking { askField }
                result
                if let status {
                    Text(status).font(Typography.caption).foregroundStyle(.secondary)
                }
                if !hasProfile { teachHandwriting }
            }
            .padding(Space.l)
        }
        .task(id: ContextKey(scope: scope, pageID: pageID)) { refreshContext() }
        .onAppear {
            hasKey = Keychain.get(Keychain.Account.featherless) != nil
            hasProfile = FileManager.default.fileExists(atPath: HandwritingProfileStore.fileURL.path)
        }
        .onDisappear { player.stop(); model.cancel() }
        .sheet(isPresented: $showingSettings, onDismiss: {
            hasKey = Keychain.get(Keychain.Account.featherless) != nil
        }) {
            NavigationStack { AISettingsView() }
        }
        .sheet(isPresented: $showingCapture, onDismiss: {
            hasProfile = FileManager.default.fileExists(atPath: HandwritingProfileStore.fileURL.path)
        }) {
            HandwritingCaptureSheet()
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Label("Study", systemImage: "sparkles").font(Typography.title)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(ToolIconButtonStyle())
                .accessibilityLabel("Close")
        }
    }

    private var noKeyCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Add a key to start").font(Typography.headline)
            Text("Study uses your own Featherless API key. Add it in Settings, then come back. Nothing is sent until you tap an action.")
                .font(Typography.caption).foregroundStyle(.secondary)
            Button("Open AI Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .surfaceCard(radius: Radius.m, elevated: false)
    }

    private var sendNote: some View {
        Text(contextReadable
             ? StudyContext.sendSummary(characterCount: contextCount, scope: scope)
             : "There is no text to read here yet. Handwriting is read in the background a few seconds after you stop writing.")
            .font(Typography.caption).foregroundStyle(.secondary)
    }

    private var tiles: some View {
        let enabled = hasKey && contextReadable && !isLoading
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.m), GridItem(.flexible(), spacing: Space.m)],
                         spacing: Space.m) {
            tile("Summarize", "text.alignleft", enabled) { send(.summarize) }
            tile("Explain", "lightbulb", enabled) { send(.explain) }
            tile("Quiz Me", "rectangle.on.rectangle.angled", enabled) { send(.quiz) }
            tile("Ask", "questionmark.bubble", hasKey && contextReadable) { asking.toggle() }
        }
    }

    private func tile(_ title: String, _ icon: String, _ enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                Image(systemName: icon).font(.title2)
                Text(title).font(Typography.label)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var askField: some View {
        HStack(spacing: Space.s) {
            TextField("Ask about your notes", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendQuestion)
            Button("Send", action: sendQuestion)
                .buttonStyle(.borderedProminent)
                .disabled(question.trimmed.isEmpty || isLoading || !hasKey)
        }
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: Space.m) {
                ProgressView()
                Text("Thinking…").font(Typography.body).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
            }
            .padding(Space.m)
            .surfaceCard(radius: Radius.m, elevated: false)
        case .failed(let error):
            VStack(alignment: .leading, spacing: Space.s) {
                Text(error.errorDescription ?? "Something went wrong.")
                    .font(Typography.body).foregroundStyle(.secondary)
                if error == .noKey || error == .unauthorized {
                    Button("Open AI Settings") { showingSettings = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .surfaceCard(radius: Radius.m, elevated: false)
        case .answer(let text):
            VStack(alignment: .leading, spacing: Space.m) {
                Text(StudyText.attributed(text))
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions(plain: StudyText.stripMarkdown(text))
            }
            .padding(Space.m)
            .surfaceCard(radius: Radius.m, elevated: false)
        case .quiz(let items):
            quizView(items)
        }
    }

    private func quizView(_ items: [QuizItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if model.quizIndex >= items.count {
                VStack(spacing: Space.s) {
                    Text("You knew \(model.knewCount) of \(items.count)").font(Typography.title)
                    Button("Go Again") { model.quizIndex = 0; model.quizFlipped = false; model.quizResults = [:] }
                }
                .frame(maxWidth: .infinity)
                .padding(Space.l)
            } else {
                let item = items[model.quizIndex]
                Text("Card \(model.quizIndex + 1) of \(items.count)").font(Typography.caption).foregroundStyle(.secondary)
                Button { model.quizFlipped.toggle() } label: {
                    VStack(spacing: Space.s) {
                        SectionLabel(model.quizFlipped ? "Answer" : "Question")
                        Text(StudyText.attributed(model.quizFlipped ? item.answer : item.question))
                            .font(Typography.headline)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !model.quizFlipped {
                            Text("Tap to flip").font(Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                HStack {
                    Button { model.quizIndex = max(0, model.quizIndex - 1); model.quizFlipped = false } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(model.quizIndex == 0)
                    Spacer()
                    if model.quizFlipped {
                        Button("Missed") { model.mark(false, count: items.count) }.buttonStyle(.bordered)
                        Button("Knew it") { model.mark(true, count: items.count) }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button { model.quizIndex += 1; model.quizFlipped = false } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
                if !model.quizResults.isEmpty {
                    Text("You knew \(model.knewCount) of \(model.quizResults.count) so far")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            actions(plain: StudyText.quizText(items))
        }
        .padding(Space.m)
        .surfaceCard(radius: Radius.m, elevated: false)
    }

    private func actions(plain: String) -> some View {
        HStack(spacing: Space.s) {
            Button {
                if player.isPlaying || player.isLoading { player.stop() } else { player.play(text: plain) }
            } label: {
                Label(player.isPlaying || player.isLoading ? "Stop" : "Read Aloud",
                      systemImage: player.isPlaying || player.isLoading ? "stop.fill" : "speaker.wave.2")
            }
            Button {
                UIPasteboard.general.string = plain
                status = "Copied."
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button {
                write(plain)
            } label: { Label("Write on Page", systemImage: "pencil.line") }
                .disabled(!canWrite || writing)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private var teachHandwriting: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Write on Page uses a built-in hand until it has yours.")
                .font(Typography.caption).foregroundStyle(.secondary)
            Button("Teach your handwriting") { showingCapture = true }
                .font(Typography.label)
        }
    }

    // MARK: Actions

    private var isLoading: Bool { if case .loading = model.phase { return true } else { return false } }

    private func refreshContext() {
        let e = entries(scope)
        contextCount = StudyContext.text(pages: e).count
        contextReadable = StudyContext.hasReadableText(e)
    }

    private func send(_ action: StudyPanelModel.Action) {
        player.stop()
        status = nil
        let e = entries(scope)
        guard StudyContext.hasReadableText(e) else { contextReadable = false; return }
        model.start(action, notes: StudyContext.text(pages: e))
    }

    private func sendQuestion() {
        let q = question.trimmed
        guard !q.isEmpty, !isLoading else { return }
        send(.ask(q))
    }

    private func write(_ plain: String) {
        status = nil
        writing = true
        let text = StudyText.forHandwriting(plain)
        Task {
            let outcome = await onWrite(text)
            status = outcome.message
            writing = false
        }
    }
}

// MARK: - Canvas insertion

extension NotebookDetailView {
    /// Writes `raw` onto the page on screen, in the pen's ink, as one undo
    /// step. The strokes are laid out off the main thread; the canvas is
    /// touched only if it is still the one the request started with. The
    /// save is the normal autosave (`scheduleAutosave` marks the canvas
    /// dirty) - nothing is written here.
    func writeStudyTextOnPage(_ raw: String) async -> StudyWriteOutcome {
        guard let page = currentPage, page.id == canvasPageID else { return .noPage }
        let (text, truncated) = StudyText.cap(raw)
        guard !text.isEmpty else { return .empty }

        let pageID = page.id
        let canvas = canvasView
        let pageRect: CGRect = page.type == "whiteboard"
            ? CGRect(x: 0, y: 0, width: WhiteboardCanvasView.boardSize, height: WhiteboardCanvasView.boardSize)
            : CGRect(origin: .zero, size: PageGeometry.contentSize(for: page))
        let zoom = viewport.zoomScale
        let visible = canvas.bounds.isEmpty
            ? pageRect
            : WriteOnPageGeometry.visibleRect(viewSize: canvas.bounds.size, zoom: zoom, offset: viewport.contentOffset)
        let placement = WriteOnPageGeometry.placement(visible: visible, page: pageRect, zoom: zoom)

        // The pen's own settings, never hardcoded. The highlighter is not
        // used even when it is in hand: 20 pt of translucent marker would
        // smear the writing.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        toolState.penColor.fixedUIColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let request = HandwritingWriter.Request(
            text: text, placement: placement, inkType: toolState.penInkType,
            rgba: [Double(r), Double(g), Double(b), Double(a)],
            width: CGFloat(toolState.penWidth), seed: UInt64.random(in: 1...UInt64.max))

        let output = await HandwritingWriter.generate(request)
        guard !output.strokes.isEmpty else { return .empty }
        // Back on the main actor: the page may have turned while this ran.
        guard currentPage?.id == pageID, canvasPageID == pageID, canvasView === canvas else { return .pageChanged }

        var drawing = canvas.drawing
        drawing.strokes.append(contentsOf: output.strokes)
        canvas.setDrawingUndoably(drawing)
        scheduleAutosave()
        return .written(truncated: truncated, runsPastPage: output.maxY > pageRect.maxY)
    }

    /// The entries the Study panel reads for `scope`.
    func studyEntries(for scope: StudyScope) -> [StudyContext.Entry] {
        let numbered = Array(sortedPages.enumerated()).map { (number: $0.offset + 1, page: $0.element) }
        let chosen = scope == .page
            ? numbered.filter { $0.page.id == currentPage?.id }
            : numbered
        return StudyContext.entries(for: chosen, documents: documentsByPageID)
    }

    var studyPanel: some View {
        StudyPanelView(
            pageID: currentPage?.id,
            canWrite: currentPage != nil && currentPage?.id == canvasPageID,
            entries: { studyEntries(for: $0) },
            onWrite: { await writeStudyTextOnPage($0) },
            onClose: { showingStudyPanel = false })
    }
}
#endif
