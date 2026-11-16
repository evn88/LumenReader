import Combine
import Foundation
import SwiftUI
import Translation
import WebKit

/// Общее для переводчиков сканов и EPUB: то, что показывает панель «Перевод».
@MainActor
protocol BookTranslating: ObservableObject {
    var target: String { get set }
    var showing: Bool { get set }
    /// Язык книги, заданный читателем (nil — автоматически).
    var sourceLanguage: String? { get set }
    /// Язык книги, определённый автоматически.
    var detectedLanguage: String? { get }
    var pendingDownload: TranslationProblem? { get }
    var downloadConfig: TranslationSession.Configuration? { get }
    var wholeBook: Bool { get }
    var bookPause: String? { get }
    var doneCount: Int { get }
    var totalCount: Int { get }
    func startBook()
    func stopBook()
    func requestDownload()
    func languagesInstalled()
}

extension BookTranslating {
    var progressLine: String { "Переведено \(min(doneCount, totalCount)) из \(totalCount)" + (bookPause.map { " · \($0)" } ?? "") }
}

extension Translator: BookTranslating {
    var doneCount: Int { done.count }
    var totalCount: Int { book.count }
}

/// Перевод EPUB: по главам. Абзацы главы (листовые блоки p, h1…, li…) переводятся и подменяются в WebView;
/// оригинальная разметка сохраняется и возвращается при выключении перевода.
@MainActor
final class EPUBTranslator: ObservableObject, BookTranslating {
    let book: EPUBBook
    /// Применить перевод к открытой главе / снять его (выставляет EPUBController).
    var apply: ((_ chapter: Int, _ units: [String?]?) -> Void)?
    /// Тексты блоков открытой главы (из WebView).
    var currentBlocks: (() async -> [String]?)?
    var currentChapter: () -> Int = { 0 }

    @Published var target: String { didSet { if target != oldValue { retarget() } } }
    @Published var showing = false { didSet { if showing != oldValue { syncMeta(); refreshCurrent() } } }
    @Published var sourceLanguage: String? {
        didSet { if sourceLanguage != oldValue { syncMeta(); done = []; problem = nil; refreshCurrent() } }
    }
    /// Язык из метаданных EPUB.
    var detectedLanguage: String? { book.language.map(LanguageGuess.base) }
    @Published private(set) var problem: TranslationProblem?
    @Published private(set) var working = false
    @Published private(set) var done: Set<Int> = []
    @Published private(set) var wholeBook = false { didSet { syncMeta() } }
    @Published private(set) var bookPause: String?
    @Published var pendingDownload: TranslationProblem?
    @Published private(set) var downloadConfig: TranslationSession.Configuration?

    private var store: TranslationStore
    private var job: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var worker: ChapterReader?
    private var modelSink: AnyCancellable?

    var doneCount: Int { done.count }
    var totalCount: Int { book.spine.count }

    init(book: EPUBBook, target: String) {
        self.book = book
        self.target = target
        store = TranslationStore(book: book.source, target: target)
        done = Set(store.keys().compactMap(Self.chapter))
        modelSink = NotificationCenter.default.publisher(for: TranslationModel.changed).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.retarget() }
        if let t = Sidecar.meta(book.source).translation {
            if let lang = t.target, lang != target, TranslationTarget.all.contains(where: { $0.code == lang }) {
                self.target = lang
                store = TranslationStore(book: book.source, target: lang)
                done = Set(store.keys().compactMap(Self.chapter))
            }
            sourceLanguage = t.source
            showing = t.showing ?? false
            if t.wholeBook == true { DispatchQueue.main.async { self.startBook() } }
        }
    }

    private static func chapter(_ key: String) -> Int? { key.hasPrefix("chapter-") ? Int(key.dropFirst(8)) : nil }
    private func key(_ i: Int) -> String { "chapter-\(i)" }

    private func syncMeta() {
        let s = showing, w = wholeBook, t = target, src = sourceLanguage
        Sidecar.update(book.source) { $0.translation = TranslationMeta(target: t, showing: s, wholeBook: w, source: src) }
    }

    private func retarget() {
        store = TranslationStore(book: book.source, target: target)
        done = Set(store.keys().compactMap(Self.chapter))
        problem = nil
        syncMeta()
        if wholeBook { job?.cancel(); job = nil; startBook() }
        refreshCurrent()
    }

    private func fingerprint(_ blocks: [String]) -> String { PageText.fingerprint(blocks + [sourceLanguage ?? ""]) }

    /// Сохранённый перевод главы, если он подходит к её текущему тексту.
    func cached(_ chapter: Int, blocks: [String]) -> [String?]? {
        guard let e = store.load(key(chapter)), e.source == fingerprint(blocks), e.units.count == blocks.count else { return nil }
        return e.units
    }

    /// Глава загрузилась (или переключили показ): перевести и подменить текст.
    func refreshCurrent() {
        current?.cancel()
        let ch = currentChapter()
        guard showing else { problem = nil; working = false; apply?(ch, nil); return }
        current = Task { [weak self] in
            guard let self, let blocks = await self.currentBlocks?(), !Task.isCancelled else { return }
            if let t = self.cached(ch, blocks: blocks) { self.apply?(ch, t); return }
            self.working = true
            self.problem = nil
            do {
                let t = try await TranslationRouter.translate(blocks, to: self.target, hint: self.detectedLanguage, source: self.sourceLanguage)
                guard !Task.isCancelled else { return }
                self.store.save(.init(source: self.fingerprint(blocks), units: t, engine: nil), self.key(ch))
                self.done.insert(ch)
                self.working = false
                if self.showing, self.currentChapter() == ch { self.apply?(ch, t) }
            } catch {
                guard !(error is CancellationError) else { return }
                self.working = false
                let p = (error as? TranslationProblem) ?? .failed(error.localizedDescription)
                self.problem = p
                if case .needsDownload = p { self.pendingDownload = p }
            }
        }
    }

    func retry() { problem = nil; refreshCurrent() }

    func requestDownload() {
        guard case .needsDownload(let s, let t) = pendingDownload ?? problem else { return }
        let c = TranslationSession.Configuration(source: Locale.Language(identifier: s), target: Locale.Language(identifier: t))
        if downloadConfig == c { downloadConfig?.invalidate() } else { downloadConfig = c }
    }

    func languagesInstalled() {
        pendingDownload = nil
        problem = nil
        done = Set(store.keys().compactMap(Self.chapter))
        bookPause = nil
        refreshCurrent()
        if wholeBook, job == nil { startBook() }
    }

    // MARK: - вся книга

    func startBook() {
        wholeBook = true
        bookPause = nil
        guard job == nil else { return }
        job = Task { [weak self] in await self?.runBook(); self?.job = nil }
    }

    func stopBook() {
        wholeBook = false
        job?.cancel(); job = nil
        bookPause = nil
    }

    private func runBook() async {
        let reader = worker ?? ChapterReader(root: book.root)
        worker = reader
        let focus = currentChapter()
        let order = Array(focus..<book.spine.count) + Array(0..<min(focus, book.spine.count))
        for i in order where !done.contains(i) {
            guard !Task.isCancelled, wholeBook else { return }
            while let why = BookModel.powerPauseReason() {
                bookPause = why
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
            }
            bookPause = nil
            let blocks = await reader.blocks(book.spine[i])
            if blocks.isEmpty { done.insert(i); continue }
            if cached(i, blocks: blocks) != nil { done.insert(i); continue }
            do {
                let t = try await TranslationRouter.translate(blocks, to: target, hint: detectedLanguage, source: sourceLanguage)
                guard !Task.isCancelled else { return }
                store.save(.init(source: fingerprint(blocks), units: t, engine: nil), key(i))
                done.insert(i)
            } catch is CancellationError {
                return
            } catch let p as TranslationProblem {
                switch p {
                case .needsDownload: pendingDownload = p; bookPause = "нужно скачать языки"; return
                case .unsupported(let s, _): bookPause = "язык «\(LanguageGuess.title(s))» не поддерживается"; done.insert(i)
                case .failed: done.insert(i)
                }
            } catch {
                done.insert(i)
            }
        }
        if done.count >= book.spine.count { wholeBook = false }
    }

    static func translateSnippet(_ text: String, to target: String) async throws -> String {
        try await Translator.translateSnippet(text, to: target)
    }
}

/// Скрытый WebView: читает тексты блоков главы тем же скриптом, что и читалка (для перевода всей книги).
@MainActor
final class ChapterReader: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let root: URL
    private var loaded: CheckedContinuation<Void, Never>?

    init(root: URL) {
        self.root = root
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(WKUserScript(source: epubScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: cfg)
        super.init()
        web.navigationDelegate = self
    }

    func blocks(_ url: URL) async -> [String] {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            loaded?.resume()
            loaded = k
            web.loadFileURL(url, allowingReadAccessTo: root)
        }
        return ((try? await web.evaluateJavaScript("SR.blocks()")) as? [String]) ?? []
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
}
