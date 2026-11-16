import Combine
import CryptoKit
import Foundation
import IOKit.ps
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Откуда берём страницу: страница PDF или файл-картинка (папка со сканами).
enum PageSource {
    static let pdfLock = NSLock()

    /// Страница PDF и её печатная метка. Метку читаем при загрузке, пока жив PDFDocument:
    /// у страницы без документа `PDFPage.label` — nil.
    case pdf(PDFPage, label: String?)
    case image(URL)

    /// Печатная метка страницы из PDF (/PageLabels), если издатель её задал.
    var label: String? {
        guard case .pdf(_, let l) = self, let l = l?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
        return l
    }

    /// Растр страницы для OCR. 300 dpi хватает Vision с запасом.
    func render(dpi: CGFloat = 300) -> CGImage? {
        switch self {
        case .image(let url):
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts = [kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
        case .pdf(let page, _):
            // PDFKit не потокобезопасен: страницы одного документа из двух потоков очереди рисуем по очереди
            PageSource.pdfLock.lock(); defer { PageSource.pdfLock.unlock() }
            let box = page.bounds(for: .mediaBox)
            // 300 dpi, но не больше ~3300 px по длинной стороне: страницы-«плакаты» (PDF из картинок)
            // иначе дают десятки мегапикселей — OCR и улучшение иллюстраций тонут
            let scale = min(dpi / 72, 3300 / max(box.width, box.height, 1))
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 0, h > 0, let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage()
        }
    }

    static func load(_ url: URL) -> (title: String, pages: [PageSource])? {
        let title = url.deletingPathExtension().lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let images = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return images.isEmpty ? nil : (title, images.map { .image($0) })
        }
        if url.pathExtension.lowercased() == "pdf" {
            // битый PDF раньше открывался «картинкой» и давал вечную ошибку; зашифрованный — пустые страницы
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
            if doc.isLocked && !doc.unlock(withPassword: "") { return nil }
            return (title, (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map { .pdf($0, label: $0.label) })
        }
        return (title, [.image(url)])
    }
}

/// Чтение/запись файлов в папке, которую синхронизирует iCloud Drive:
/// через NSFileCoordinator (не читаем файл, пока его докачивает/пишет демон синхронизации)
/// и атомарно (другое устройство никогда не увидит недописанный файл).
enum SyncedFile {
    static func read(_ url: URL) -> Data? {
        let fm = FileManager.default
        // ещё не скачанный файл iCloud: просим скачать; координированное чтение дождётся данных
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: url)
        } else if !fm.fileExists(atPath: url.path) {
            return nil
        }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }

    static func write(_ data: Data, to url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
            try? data.write(to: $0, options: .atomic)
        }
    }
}

/// Кеш раскладок: OCR страницы делается один раз.
/// Хранится рядом с книгой (`.scanreader/<книга>/…`), поэтому в общей папке iCloud Drive
/// результат распознавания получают все участники, в том числе с другим Apple ID.
/// Если папка книги недоступна для записи — локально в Application Support.
struct LayoutCache {
    static let version = "v4"   // меняем при изменении анализа — старые раскладки пересчитаются
    let dir: URL

    init(bookURL: URL, palette: FontPalette, languages: [String]) {
        // ключ не содержит путь: у разных учёток путь к общей папке разный
        // гарнитура — свойство скана: анализ всегда по эталонной паре шрифтов, тема на ключ не влияет
        _ = palette
        let key = "\(Self.version)|\(languages)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let fm = FileManager.default
        let sidecar = bookURL.deletingLastPathComponent()
            .appendingPathComponent(".scanreader/\(bookURL.lastPathComponent)/layouts-\(hash)", isDirectory: true)
        if (try? fm.createDirectory(at: sidecar, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: sidecar.path) {
            dir = sidecar
        } else {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // локальный запасной кеш: в ключ — полный путь, иначе две «book.pdf» из разных мест делят кеш
            let local = SHA256.hash(data: Data((key + "|" + bookURL.path).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            dir = base.appendingPathComponent("\(Product.dataFolder)/layouts/\(bookURL.lastPathComponent)-\(local)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Раскладка страницы уже есть (локально или ещё в iCloud): PNG иллюстраций пишутся раньше неё.
    func has(_ i: Int) -> Bool {
        let url = dir.appendingPathComponent("page-\(i).json")
        if FileManager.default.fileExists(atPath: url.path) { return true }
        // не скачанный файл iCloud на macOS виден как ".page-N.json.icloud" (старые версии) или dataless
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(".page-\(i).json.icloud").path)
    }

    func load(_ i: Int) -> PageLayout? {
        guard let data = SyncedFile.read(dir.appendingPathComponent("page-\(i).json")) else { return nil }
        return try? JSONDecoder().decode(PageLayout.self, from: data)
    }

    func save(_ layout: PageLayout, _ i: Int) {
        if let data = try? JSONEncoder().encode(layout) {
            SyncedFile.write(data, to: dir.appendingPathComponent("page-\(i).json"))
        }
    }

    /// Страница целиком: раскладка из кеша или распознавание + сохранение;
    /// улучшенные иллюстрации — так же (PNG рядом с раскладкой).
    static func process(_ source: PageSource, index i: Int, cache: LayoutCache,
                        analyzer: LayoutAnalyzer, token: CancelToken? = nil) throws -> (page: AnalyzedPage, fromCache: Bool) {
        try token?.check()
        guard let image = source.render() else { throw PageError.unreadable }
        try token?.check()
        let cached = cache.load(i)
        var analyzer = analyzer
        analyzer.token = token
        let page = try analyzer.analyze(image, cached: cached, store: FigureStore(dir: cache.dir, page: i))
        if cached == nil { cache.save(page.layout, i) }
        return (page, cached != nil)
    }
}

enum PageError: LocalizedError {
    case unreadable
    var errorDescription: String? { "Страница не читается: файл повреждён или недоступен" }
}

@MainActor
final class BookModel: ObservableObject {
    let url: URL
    let title: String
    let sources: [PageSource]
    @Published private(set) var pages: [Int: AnalyzedPage] = [:]
    @Published private(set) var failed: [Int: String] = [:]
    /// Шрифты отображения. Распознавание от них не зависит — смена только перерисовывает страницы.
    @Published var palette: FontPalette { didSet { if palette != oldValue { reflowMemo = [:] } } }
    @Published var languages: [String] = ["ru-RU", "en-US"] { didSet { if languages != oldValue { reset() } } }
    /// Улучшать иллюстрации (увеличение, чистые заливки, перенабор надписей).
    @Published var enhanceFigures = true { didSet { if enhanceFigures != oldValue { reset() } } }

    /// Владелец задач в общей очереди распознавания (на каждое поколение настроек — свой).
    private var owner = UUID()
    /// Страница → id задачи: завершение старой (отменённой) задачи не снимает флаг новой.
    private var inFlight: [Int: UUID] = [:]
    private var generation = 0
    private var cache: LayoutCache
    private var closed = false
    private let queueRef = RecognitionQueue.shared
    /// Хайлайты и заметки книги (annotations.json рядом с книгой).
    let annotations: AnnotationStore
    private var annotationsSink: AnyCancellable?

    var count: Int { sources.count }

    /// Номер страницы для читателя — один для подписи под страницей, меню, оглавления, поиска и заметок:
    /// печатная метка PDF (если есть), иначе индекс + 1.
    func displayNumber(for i: Int) -> String {
        guard sources.indices.contains(i) else { return "\(i + 1)" }
        if hasPrintedLabels { return labels[i] }
        // меток нет — печатный номер из распознанных колонтитулов (если ≥ 2 страницы согласны)
        if let off = printedOffset, i + 1 + off > 0 { return "\(i + 1 + off)" }
        return "\(i + 1)"
    }

    /// Метки всех страниц (считаются один раз: PDFPage.label на каждый кадр дорог).
    /// PDFKit для PDF без /PageLabels отдаёт «1», «2»… — это не печатные номера.
    private(set) lazy var labels: [String] = sources.enumerated().map { i, s in s.label ?? "\(i + 1)" }
    private(set) lazy var hasPrintedLabels: Bool = labels.enumerated().contains { $0.element != "\($0.offset + 1)" }

    /// Сдвиг «печатный номер − (индекс + 1)», выведенный из колонтитулов распознанных страниц.
    @Published private(set) var printedOffset: Int?
    private var pageOffsets: [Int: Int] = [:]

    /// Номер страницы в колонтитуле: короткая строка из одних цифр у верхнего или нижнего края.
    nonisolated static func printedNumber(in layout: PageLayout) -> Int? {
        let H = layout.size.height
        for l in layout.allLines where l.bounds.maxY < H * 0.09 || l.bounds.minY > H * 0.91 {
            for w in l.words where w.text.count <= 4 {
                if let n = Int(w.text), n > 0 { return n }
            }
        }
        return nil
    }

    private func notePrintedNumber(_ i: Int, _ layout: PageLayout) {
        guard !hasPrintedLabels, let n = Self.printedNumber(in: layout) else { return }
        // голос — один на страницу (одна страница может распознаваться дважды: упреждение и фон);
        // сдвиг принимаем, если с ним согласны ≥ 2 разные страницы и большинство распознанных
        pageOffsets[i] = n - (i + 1)
        printedOffset = Self.consensusOffset(pageOffsets)
    }

    nonisolated static func consensusOffset(_ byPage: [Int: Int]) -> Int? {
        var votes: [Int: Int] = [:]
        for off in byPage.values { votes[off, default: 0] += 1 }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 2,
              Double(best.value) / Double(byPage.count) >= 0.6 else { return nil }
        return best.key
    }

    init?(url: URL, palette: FontPalette = .original) {
        guard let loaded = PageSource.load(url), !loaded.pages.isEmpty else { return nil }
        self.url = url
        title = loaded.title
        sources = loaded.pages
        self.palette = palette
        cache = LayoutCache(bookURL: url, palette: palette, languages: ["ru-RU", "en-US"])
        let meta = Sidecar.meta(url)
        showScan = Set(meta.pagesShowOriginal ?? [])
        forceText = Set(meta.pagesForceText ?? [])
        noScanEnhance = Set(meta.pagesNoScanEnhance ?? [])
        annotations = AnnotationStore(book: url)
        // страницы перерисовываются при изменении хайлайтов
        annotationsSink = annotations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        scanCache()
    }

    /// Смена шрифтов/языков/улучшения: старые задачи отменяются, видимые страницы запрашиваются заново
    /// (раньше они оставались спиннером, пока не подхватит фон — а на батарее фон стоит).
    private func reset() {
        queueRef.cancel(owner: owner)
        owner = UUID()
        generation += 1
        pages = [:]; failed = [:]; inFlight = [:]; queue = []; unreliable = []; enhancedScans = [:]; enhancing = []
        cache = LayoutCache(bookURL: url, palette: palette, languages: languages)
        background?.cancel(); background = nil; backgroundPage = nil
        reflowMemo = [:]; screenCounts = [:]; neighborLayouts = [:]
        scanCache()
        if let settings = countsSettings { countsSettings = nil; updateScreenCounts(settings) }
        if !lastVisible.isEmpty { prefetch(visible: lastVisible) }
    }

    /// Окно книги закрыто: всё её распознавание (упреждение, фон, идущие запросы Vision) останавливается.
    func close() {
        guard !closed else { return }
        closed = true
        background?.cancel(); background = nil
        countsTask?.cancel()
        queueRef.cancel(owner: owner)
        queue = []; inFlight = [:]
        pages = [:]
    }

    /// Повтор после ошибки (кнопка на странице).
    func retry(_ i: Int) {
        failed[i] = nil
        request(i)
    }

    // MARK: - показывать скан вместо распознанного текста

    /// Страницы, которые читатель велел показывать сканом (синхронизируется через meta.json).
    @Published private(set) var showScan: Set<Int> = []
    /// Страницы, где читатель попросил текст, хотя распознавание сочтено ненадёжным.
    @Published private(set) var forceText: Set<Int> = []
    /// Ненадёжно распознанные страницы (низкая уверенность OCR или много «мусорных» слов).
    @Published private(set) var unreliable: Set<Int> = []

    /// Показывать ли эту страницу сканом.
    func showsScan(_ i: Int) -> Bool { showScan.contains(i) || (unreliable.contains(i) && !forceText.contains(i)) }

    func setShowScan(_ i: Int, _ on: Bool) {
        if on { showScan.insert(i); forceText.remove(i) } else { showScan.remove(i) }
        saveScanPrefs()
        if on, let p = pages[i], p.leveled == nil { level(i, p) }
        if !on, pages[i]?.scanOnly == true { pages[i] = nil; request(i) }      // «Распознать заново»
        objectWillChange.send()
    }

    /// Ненадёжная страница: всё же показать распознанный текст.
    func showTextAnyway(_ i: Int) {
        forceText.insert(i); showScan.remove(i)
        saveScanPrefs()
    }

    /// Распознать страницу заново (кеш раскладки этой страницы удаляется).
    func recognizeAgain(_ i: Int) {
        try? FileManager.default.removeItem(at: cache.dir.appendingPathComponent("page-\(i).json"))
        for f in (try? FileManager.default.contentsOfDirectory(atPath: cache.dir.path)) ?? [] where f.hasPrefix("page-\(i)-figure-") {
            try? FileManager.default.removeItem(at: cache.dir.appendingPathComponent(f))
        }
        cached.remove(i)
        showScan.remove(i); forceText.remove(i); unreliable.remove(i)
        saveScanPrefs()
        pages[i] = nil; failed[i] = nil
        request(i)
    }

    /// Уровни для страницы, которую только что решили показывать сканом.
    private func level(_ i: Int, _ p: AnalyzedPage) {
        let original = p.original, gen = generation
        Task.detached(priority: .userInitiated) {
            let img = AnalyzedPage.leveled(original)
            await MainActor.run {
                guard gen == self.generation, var page = self.pages[i] else { return }
                page.leveled = img
                self.pages[i] = page
            }
        }
    }

    private func saveScanPrefs() {
        let a = showScan.sorted(), b = forceText.sorted(), c = noScanEnhance.sorted()
        Sidecar.update(url) { $0.pagesShowOriginal = a; $0.pagesForceText = b; $0.pagesNoScanEnhance = c }
    }

    // MARK: - улучшенный скан (для показа страницы «оригиналом»)

    /// Общая настройка «Улучшать сканы» (из «Оформления»).
    @Published var enhanceScans = true
    /// Страницы, где читатель выключил улучшение скана (meta.json).
    @Published private(set) var noScanEnhance: Set<Int> = []
    /// Готовые улучшенные сканы страниц окна чтения.
    @Published private(set) var enhancedScans: [Int: CGImage] = [:]
    private var enhancing: Set<Int> = []

    func wantsEnhancedScan(_ i: Int) -> Bool { enhanceScans && !noScanEnhance.contains(i) }

    func setScanEnhance(_ i: Int, _ on: Bool) {
        if on { noScanEnhance.remove(i) } else { noScanEnhance.insert(i); enhancedScans[i] = nil }
        saveScanPrefs()
        if on { requestEnhancedScan(i) }
    }

    /// Улучшенный скан страницы: из кеша книги (page-N-scan.png) или расчёт в общей очереди (отменяется с книгой).
    /// Пока не готов, страница показывается обычным сканом.
    func requestEnhancedScan(_ i: Int) {
        guard wantsEnhancedScan(i), enhancedScans[i] == nil, !enhancing.contains(i), !closed,
              let page = pages[i] else { return }
        enhancing.insert(i)
        let original = page.original, file = cache.dir.appendingPathComponent("page-\(i)-scan.png"), gen = generation
        let palette = self.palette
        Task { [weak self] in
            guard let self else { return }
            let img: CGImage? = await withCheckedContinuation { (k: CheckedContinuation<CGImage?, Never>) in
                self.queueRef.submit(owner: self.owner, page: i, priority: .visible) { token in
                    if let data = SyncedFile.read(file), let src = CGImageSourceCreateWithData(data as CFData, nil),
                       let cached = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        k.resume(returning: cached); return
                    }
                    guard !token.isCancelled, let gray = GrayBitmap(cgImage: original),
                          let out = FigureEnhancer(palette: palette).enhancePage(gray, token: token), !token.isCancelled
                    else { k.resume(returning: nil); return }
                    let d = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, out, nil)
                        if CGImageDestinationFinalize(dest) { SyncedFile.write(d as Data, to: file) }
                    }
                    k.resume(returning: out)
                }
            }
            guard gen == self.generation, !self.closed else { return }
            self.enhancing.remove(i)
            if let img, self.window.contains(i), self.wantsEnhancedScan(i) { self.enhancedScans[i] = img }
        }
    }

    // MARK: - фоновая обработка всей книги

    /// Страницы, раскладка которых уже лежит в кеше (с любого устройства).
    @Published private(set) var cached: Set<Int> = []
    /// Почему фон стоит: nil — работает или ждёт простоя.
    @Published private(set) var backgroundPause: String?
    @Published private(set) var backgroundPage: Int?
    var idleDelay: TimeInterval = 3
    private var background: Task<Void, Never>?
    private var focus = 0

    private func scanCache() {
        let c = cache
        cached = Set((0..<count).filter { c.has($0) })
    }

    /// Любое действие читателя: фон останавливается и стартует снова после простоя.
    private func touch() {
        guard !closed else { return }
        background?.cancel()
        queueRef.cancel(owner: owner, priorities: [.background])
        background = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.idleDelay ?? 3))
            guard !Task.isCancelled else { return }
            await self?.runBackground()
        }
    }

    /// По одной странице с низким приоритетом: от текущей вперёд, затем назад.
    /// Результат — только на диск; в памяти остаётся, лишь если попал в окно чтения.
    /// Страницы «показывать сканом» не распознаются.
    private func runBackground() async {
        while !Task.isCancelled && !closed {
            // упреждение и видимые страницы всегда впереди
            guard queue.isEmpty, inFlight.isEmpty else {
                try? await Task.sleep(for: .seconds(1)); continue
            }
            if let why = Self.powerPauseReason() {
                backgroundPause = why
                try? await Task.sleep(for: .seconds(30)); continue
            }
            backgroundPause = nil
            let order = Array(focus..<count) + Array((0..<focus).reversed())
            guard let i = order.first(where: { !cached.contains($0) && failed[$0] == nil && !showScan.contains($0) }) else { break }
            backgroundPage = i
            let gen = generation
            let outcome = await run(i, priority: .background)
            guard gen == generation, !Task.isCancelled else { return }
            switch outcome {
            case .success(let page):
                accept(i, page)
            case .failure(let e):
                if !(e is CancellationError) { failed[i] = Self.describe(e) }
            }
        }
        backgroundPage = nil
    }

    /// Пауза фона: режим энергосбережения или батарея (без зарядки) ниже 20%.
    nonisolated static func powerPauseReason() -> String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "режим энергосбережения" }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0
            else { continue }
            let pct = cap * 100 / mx
            if pct < 20 { return "батарея \(pct)%" }
        }
        return nil
    }

    /// Сколько страниц вперёд распознаём заранее.
    var lookahead = 6
    /// Сколько уже пройденных страниц держим в памяти (листание назад без задержки).
    var keepBehind = 2
    private var queue: [Int] = []
    private var lastVisible: [Int] = []
    /// Страницы, которые держим в памяти: каждая — растр 300 dpi + иллюстрации.
    private var window: Range<Int> = 0..<0

    /// Показываемые страницы — первыми, затем упреждение вперёд (и одна назад).
    func prefetch(visible: [Int]) {
        guard let first = visible.first, !closed else { return }
        lastVisible = visible
        focus = first
        touch()
        let ahead = (visible.last ?? first) + 1
        var wanted = visible + Array(ahead..<min(count, ahead + lookahead))
        if first > 0 { wanted.append(first - 1) }
        window = max(0, first - keepBehind)..<min(count, ahead + lookahead)
        if pages.keys.contains(where: { !window.contains($0) }) {
            pages = pages.filter { window.contains($0.key) }
            reflowMemo = [:]
        }
        if enhancedScans.keys.contains(where: { !window.contains($0) }) {
            enhancedScans = enhancedScans.filter { window.contains($0.key) }
        }
        // задачи этой книги за пределами окна больше не нужны (быстрое листание)
        queueRef.cancel(owner: owner, keeping: Set(wanted), priorities: [.ahead, .visible])
        inFlight = inFlight.filter { wanted.contains($0.key) }
        queue = wanted.filter { pages[$0] == nil && failed[$0] == nil && inFlight[$0] == nil }
        let vis = Set(visible)
        for i in queue { start(i, priority: vis.contains(i) ? .visible : .ahead) }
        queue = []
    }

    func request(_ i: Int) {
        guard sources.indices.contains(i), pages[i] == nil, inFlight[i] == nil, !closed else { return }
        if !window.contains(i) { window = min(window.lowerBound, i)..<max(window.upperBound, i + 1) }
        touch()
        start(i, priority: .visible)
    }

    private func start(_ i: Int, priority: RecognitionQueue.Priority) {
        guard sources.indices.contains(i), pages[i] == nil, failed[i] == nil, inFlight[i] == nil else { return }
        let id = UUID()
        inFlight[i] = id
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(i, priority: priority)
            guard gen == self.generation, !self.closed, self.inFlight[i] == id else { return }
            self.inFlight[i] = nil
            switch outcome {
            case .success(let page): self.accept(i, page)
            case .failure(let e): if !(e is CancellationError) { self.failed[i] = Self.describe(e) }
            }
        }
    }

    /// Задача в общей очереди распознавания; для страниц «показывать сканом» — только растр, без OCR.
    private func run(_ i: Int, priority: RecognitionQueue.Priority) async -> Result<AnalyzedPage, Error> {
        let source = sources[i], store = cache
        // эталонные шрифты (Times/Helvetica) для подбора гарнитуры: шрифты темы её искажали
        let analyzer = LayoutAnalyzer(palette: .original, languages: languages, enhanceFigures: enhanceFigures)
        let scanOnly = showScan.contains(i) && !cached.contains(i)
        let wantLeveled = showsScan(i)
        return await withCheckedContinuation { (k: CheckedContinuation<Result<AnalyzedPage, Error>, Never>) in
            queueRef.submit(owner: owner, page: i, priority: priority) { token in
                k.resume(returning: Result {
                    if scanOnly {
                        try token.check()
                        guard let image = source.render() else { throw PageError.unreadable }
                        return AnalyzedPage(scanOnly: image)
                    }
                    // раскладка и улучшенные картинки сохраняются рядом с книгой (общая iCloud-папка)
                    var page = try LayoutCache.process(source, index: i, cache: store, analyzer: analyzer, token: token).page
                    if wantLeveled || PageQuality.isUnreliableByConfidence(page.layout) { page.leveled = AnalyzedPage.leveled(page.original) }
                    return page
                })
            }
        }
    }

    private func accept(_ i: Int, _ page: AnalyzedPage) {
        if !page.scanOnly {
            cached.insert(i)
            notePrintedNumber(i, page.layout)
            reflowMemo = [:]        // соседи узнают о переносе через границу страницы
            countScreens(i, page.layout)
            if PageQuality.isUnreliable(page.layout) {
                unreliable.insert(i)
                if page.leveled == nil, !forceText.contains(i) { level(i, page) }
            } else { unreliable.remove(i) }
        }
        // вне окна страницу не держим: она уже на диске, вернуть её из кеша — доли секунды
        if window.contains(i) { pages[i] = page }
    }

    static func describe(_ e: Error) -> String {
        if let p = e as? PageError { return p.localizedDescription }
        let ns = e as NSError
        return "Не удалось распознать страницу: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    // MARK: - экранные страницы (масштаб текста ≠ 100%)

    /// Число экранных страниц у страниц скана при текущих настройках перекомпоновки.
    @Published private(set) var screenCounts: [Int: Int] = [:]
    private var countsSettings: ReflowSettings?
    private var countsTask: Task<Void, Never>?
    private var reflowMemo: [String: [ScreenPage]] = [:]

    /// Экранные страницы страницы скана (только для страниц в памяти).
    /// Перенос через границу страниц: раскладки соседей из памяти или кеша (маленький JSON).
    private var neighborLayouts: [Int: PageLayout] = [:]

    func layoutIfKnown(_ i: Int) -> PageLayout? {
        guard sources.indices.contains(i), !showsScan(i) else { return nil }
        if let p = pages[i], !p.scanOnly { return p.layout }
        if let l = neighborLayouts[i] { return l }
        guard cached.contains(i), let l = cache.load(i) else { return nil }
        if neighborLayouts.count > 16 { neighborLayouts = [:] }
        neighborLayouts[i] = l
        return l
    }

    /// (страница начинается с окончания переноса; начало следующей страницы для склейки).
    func carries(_ i: Int, _ layout: PageLayout) -> (Bool, String?) {
        let cin = Reflow.carry(from: layoutIfKnown(i - 1), to: layout)
        var cout: String?
        if let next = layoutIfKnown(i + 1), let a = Reflow.lastBodyWord(layout), let b = Reflow.firstBodyWord(next),
           Dehyphen.isCandidate(a, b) { cout = b }
        return (cin, cout)
    }

    func screens(_ i: Int, theme: ReaderTheme, settings: ReflowSettings) -> [ScreenPage]? {
        guard let page = pages[i] else { return nil }
        let key = "\(i)|\(theme.name)|\(theme.isDark)|\(settings.hashValue)"
        if let m = reflowMemo[key] { return m }
        let (cin, cout) = carries(i, page.layout)
        let r = Reflow.paginate(page.layout, palette: palette, ink: theme.ink, isDark: theme.isDark, settings: settings,
                                carryIn: cin, carryOut: cout)
        reflowMemo[key] = r
        // вызывается из body view: публикуем не во время обновления, а следующим проходом
        if screenCounts[i] != r.count, countsSettings == settings {
            DispatchQueue.main.async { if self.countsSettings == settings { self.screenCounts[i] = r.count } }
        }
        return r
    }

    /// Число экранных страниц; nil — страница ещё не распознана (считаем как одну).
    func screenCount(_ i: Int, settings: ReflowSettings) -> Int? {
        guard settings.reflows, !showsScan(i) else { return 1 }
        return countsSettings == settings ? screenCounts[i] : nil
    }

    /// Пересчёт для всех страниц, чья раскладка уже есть (в памяти или в кеше — с любого устройства).
    func updateScreenCounts(_ settings: ReflowSettings) {
        guard settings.reflows else { countsSettings = settings; screenCounts = [:]; return }
        guard countsSettings != settings else { return }
        countsSettings = settings
        screenCounts = [:]
        let layouts = pages.mapValues(\.layout), store = cache, pal = palette, known = cached, gen = generation
        countsTask?.cancel()        // ползунок масштаба: промежуточные значения не пересчитываем целиком
        countsTask = Task.detached(priority: .utility) {
            var counts: [Int: Int] = [:]
            for i in known.sorted() {
                if Task.isCancelled { return }
                guard let l = layouts[i] ?? store.load(i) else { continue }
                counts[i] = Reflow.paginate(l, palette: pal, ink: CGColor(gray: 0, alpha: 1), isDark: false, settings: settings).count
            }
            await MainActor.run {
                guard gen == self.generation, self.countsSettings == settings else { return }
                self.screenCounts.merge(counts) { a, _ in a }
            }
        }
    }

    private func countScreens(_ i: Int, _ layout: PageLayout) {
        guard let settings = countsSettings, settings.reflows, screenCounts[i] == nil else { return }
        screenCounts[i] = Reflow.paginate(layout, palette: palette, ink: CGColor(gray: 0, alpha: 1), isDark: false, settings: settings).count
    }

    /// Поиск по распознанному тексту: страницы в памяти + раскладки в кеше
    /// (в т.ч. распознанные на другом устройстве и уже синхронизированные).
    func find(_ query: String, after page: Int) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, count > 0 else { return nil }
        let order = Array((page + 1)..<count) + Array(0...min(page, count - 1))
        return order.first { (pages[$0]?.layout ?? cache.load($0))?.plainText.localizedCaseInsensitiveContains(q) == true }
    }
}
