import Combine
import Foundation
import SwiftUI
import Translation

/// Перевод книги-скана (PDF, папка сканов): страница на экране, вся книга в фоне, выделенный фрагмент.
/// Переводы абзацев кешируются рядом с книгой — с любого устройства книга открывается уже переведённой.
@MainActor
final class Translator: ObservableObject {
    unowned let book: BookModel

    /// Язык перевода (общая настройка приложения).
    @Published var target: String { didSet { if target != oldValue { retarget() } } }
    /// Показывать перевод вместо распознанного текста.
    @Published var showing = false { didSet { if showing != oldValue { syncMeta(); if showing { requestVisible() } } } }
    /// Переводы страниц в памяти: страница → абзацы (nil — абзац уже на нужном языке).
    @Published private(set) var pages: [Int: [String?]] = [:]
    /// Ошибка перевода страницы (не скачаны языки, язык не поддерживается…).
    @Published private(set) var problems: [Int: TranslationProblem] = [:]
    /// Страницы с готовым переводом в кеше.
    @Published private(set) var done: Set<Int> = []
    /// Фоновый перевод всей книги.
    @Published private(set) var wholeBook = false { didSet { syncMeta() } }
    @Published private(set) var bookPage: Int?
    /// Почему перевод книги стоит (пауза питания, не скачаны языки…).
    @Published private(set) var bookPause: String?
    /// Последняя ошибка, требующая действия (скачать языки) — показывается в окне перевода.
    @Published var pendingDownload: TranslationProblem?
    /// Запрос системного диалога скачивания языков (TranslationDownloader в окне книги).
    @Published private(set) var downloadConfig: TranslationSession.Configuration?

    func requestDownload() {
        guard case .needsDownload(let s, let t) = pendingDownload ?? problems.values.first(where: {
            if case .needsDownload = $0 { return true }; return false }) else { return }
        let c = TranslationSession.Configuration(source: Locale.Language(identifier: s), target: Locale.Language(identifier: t))
        if downloadConfig == c { downloadConfig?.invalidate() } else { downloadConfig = c }
    }

    private var store: TranslationStore
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var visible: [Int] = []
    private var job: Task<Void, Never>?
    private var sink: AnyCancellable?

    init(book: BookModel, target: String) {
        self.book = book
        self.target = target
        store = TranslationStore(book: book.url, target: target)
        done = Set(store.keys().compactMap(Self.page))
        let meta = Sidecar.meta(book.url)
        if let t = meta.translation {
            if let lang = t.target, TranslationTarget.all.contains(where: { $0.code == lang }), lang != target {
                self.target = lang
                store = TranslationStore(book: book.url, target: lang)
                done = Set(store.keys().compactMap(Self.page))
            }
            showing = t.showing ?? false
            if t.wholeBook == true { startBook() }
        }
        // новые распознанные страницы: если перевод включён и они на экране — переводим
        sink = book.$cached.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.requestVisible() }
        }
    }

    private static func page(_ key: String) -> Int? { key.hasPrefix("page-") ? Int(key.dropFirst(5)) : nil }
    private func key(_ i: Int) -> String { "page-\(i)" }

    var progressText: String { "Переведено \(min(done.count, book.count)) из \(book.count)" }

    private func syncMeta() {
        let s = showing, w = wholeBook, t = target
        Sidecar.update(book.url) { $0.translation = TranslationMeta(target: t, showing: s, wholeBook: w) }
    }

    private func retarget() {
        for t in inFlight.values { t.cancel() }
        inFlight = [:]
        pages = [:]; problems = [:]; memo = [:]
        store = TranslationStore(book: book.url, target: target)
        done = Set(store.keys().compactMap(Self.page))
        syncMeta()
        if wholeBook { job?.cancel(); startBook() }
        requestVisible()
    }

    // MARK: - страница на экране

    /// Видимые страницы (и одна вперёд) — переводятся, пока включён показ перевода.
    func setVisible(_ v: [Int]) {
        visible = v
        let keep = Set(v + v.map { $0 + 1 } + v.map { $0 - 1 })
        if pages.keys.contains(where: { !keep.contains($0) }) { pages = pages.filter { keep.contains($0.key) } }
        for (i, t) in inFlight where !keep.contains(i) { t.cancel(); inFlight[i] = nil }
        requestVisible()
    }

    private func requestVisible() {
        guard showing else { return }
        var wanted = visible
        if let last = visible.last, last + 1 < book.count { wanted.append(last + 1) }
        for i in wanted { request(i) }
    }

    func translation(_ i: Int) -> [String?]? { pages[i] }

    private var memo: [String: (AnalyzedPage, [ScreenPage])] = [:]

    /// Переведённая страница, свёрстанная под текущие настройки: столько же экранных страниц, сколько у
    /// оригинала (перевод обычно длиннее — кегль уменьшается, пока текст не поместится).
    func screens(_ i: Int, page: AnalyzedPage, palette: FontPalette, theme: ReaderTheme,
                 settings: ReflowSettings, screens target: Int) -> (AnalyzedPage, [ScreenPage])? {
        guard let t = pages[i] else { return nil }
        let key = "\(i)|\(theme.name)|\(theme.isDark)|\(settings.hashValue)|\(palette.hashValue)|\(target)"
        if let m = memo[key] { return m }
        let layout = PageText.translatedLayout(page.layout, t)
        var s = settings
        // при 100% исходная раскладка точная, перевод же всегда перекомпонуется
        if !s.reflows { s.scale = 1.0001 }
        var out = Reflow.paginate(layout, palette: palette, ink: theme.ink, isDark: theme.isDark, settings: s)
        let minScale = s.scale * 0.62
        while out.count > max(1, target), s.scale > minScale {
            s.scale *= 0.95
            out = Reflow.paginate(layout, palette: palette, ink: theme.ink, isDark: theme.isDark, settings: s)
        }
        var tp = page
        tp.layout = layout
        tp.fallbackLines = [:]
        if memo.count > 24 { memo = [:] }
        memo[key] = (tp, out)
        return (tp, out)
    }

    func retry(_ i: Int) {
        problems[i] = nil
        pendingDownload = nil
        request(i)
    }

    func request(_ i: Int) {
        guard pages[i] == nil, inFlight[i] == nil, problems[i] == nil, let layout = book.layoutIfKnown(i) else { return }
        let units = PageText.units(layout)
        let fp = PageText.fingerprint(units), store = self.store, k = key(i), target = self.target
        inFlight[i] = Task { [weak self] in
            let result: Result<[String?], Error>
            if let e = store.load(k), e.source == fp, e.units.count == units.count {
                result = .success(e.units)
            } else {
                do {
                    let t = try await TranslationRouter.translate(units, to: target)
                    store.save(.init(source: fp, units: t, engine: nil), k)
                    result = .success(t)
                } catch { result = .failure(error) }
            }
            guard let self, !Task.isCancelled, self.target == target else { return }
            self.inFlight[i] = nil
            switch result {
            case .success(let t): self.memo = [:]; self.pages[i] = t; self.done.insert(i)
            case .failure(let e): self.fail(i, e)
            }
        }
    }

    private func fail(_ i: Int, _ e: Error) {
        guard !(e is CancellationError) else { return }
        let p = (e as? TranslationProblem) ?? .failed(e.localizedDescription)
        problems[i] = p
        if case .needsDownload = p { pendingDownload = p }
    }

    /// Языки скачаны — снимаем ошибки и переводим заново.
    func languagesInstalled() {
        pendingDownload = nil
        problems = problems.filter { if case .needsDownload = $0.value { return false }; return true }
        bookPause = nil
        requestVisible()
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
        bookPage = nil; bookPause = nil
    }

    /// По страницам от текущей вперёд, затем с начала. Страницы без распознавания ждут фонового OCR;
    /// пока перевод книги идёт, фон распознавания работает и при открытой книге.
    private func runBook() async {
        while !Task.isCancelled, wholeBook {
            if let why = BookModel.powerPauseReason() {
                bookPause = why
                try? await Task.sleep(for: .seconds(30)); continue
            }
            let focus = visible.first ?? 0
            let order = Array(focus..<book.count) + Array(0..<min(focus, book.count))
            let todo = order.filter { !done.contains($0) && !book.showsScan($0) }
            if todo.isEmpty { break }
            guard let i = todo.first(where: { book.cached.contains($0) }) else {
                bookPage = nil
                bookPause = "ждём распознавания страниц"
                try? await Task.sleep(for: .seconds(3)); continue
            }
            guard let layout = book.layoutIfKnown(i) else { done.insert(i); continue }
            bookPause = nil
            bookPage = i
            let units = PageText.units(layout)
            let fp = PageText.fingerprint(units)
            if let e = store.load(key(i)), e.source == fp { done.insert(i); continue }
            do {
                let t = try await TranslationRouter.translate(units, to: target)
                guard !Task.isCancelled else { return }
                store.save(.init(source: fp, units: t, engine: nil), key(i))
                done.insert(i)
                if visible.contains(i) || visible.contains(i - 1) { memo = [:]; pages[i] = t }
            } catch is CancellationError {
                return
            } catch let p as TranslationProblem {
                bookPage = nil
                switch p {
                case .needsDownload: pendingDownload = p; bookPause = "нужно скачать языки"; job = nil; return
                case .unsupported(let s, _):
                    bookPause = "язык «\(LanguageGuess.title(s))» не поддерживается"
                    done.insert(i)       // страницу пропускаем, остальное переводим
                case .failed: try? await Task.sleep(for: .seconds(5))
                }
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
        bookPage = nil
        if done.count >= book.count { wholeBook = false }
    }

    // MARK: - выделенный фрагмент

    /// Перевод фрагмента (для меню выделения). Язык — по самому фрагменту.
    static func translateSnippet(_ text: String, to target: String) async throws -> String {
        let r = try await TranslationRouter.translate([text], to: target)
        guard let t = r.first else { return text }
        return t ?? text
    }
}

/// Настройки перевода книги в meta.json: восстанавливаются при открытии на любом устройстве.
struct TranslationMeta: Codable, Equatable {
    var target: String?
    var showing: Bool?
    var wholeBook: Bool?
}
