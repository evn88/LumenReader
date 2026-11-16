import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct ScanReaderApp: App {
    init() {
        // Режим командной строки для проверки без интерфейса:
        //   swift run -c release ScanReader --render scan.png clean.png [sepia|white|night]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), args.count > i + 2 {
            exit(RenderCLI.run(input: args[i + 1], output: args[i + 2],
                               themeName: args.count > i + 3 ? args[i + 3] : "sepia",
                               scalePercent: args.count > i + 4 ? Double(args[i + 4]) ?? 100 : 100))
        }
        //   ScanReader --enhance-scan <скан> <вывод.png> — улучшение скана страницы (как при показе «оригиналом»)
        if let i = args.firstIndex(of: "--enhance-scan"), args.count > i + 2 {
            guard let loaded = PageSource.load(URL(fileURLWithPath: args[i + 1])), let img = loaded.pages.first?.render(),
                  let gray = GrayBitmap(cgImage: img) else { print("Не удалось открыть"); exit(1) }
            let t0 = Date()
            guard let out = FigureEnhancer(palette: .original).enhancePage(gray),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[i + 2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { exit(1) }
            CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
            print(String(format: "Улучшено за %.2f с: %@", Date().timeIntervalSince(t0), args[i + 2]))
            exit(0)
        }
        //   ScanReader --prefetch <книга: PDF/папка/картинка> [первая] [сколько]
        //   — обработка страниц через кеш у книги (как при чтении), печать попаданий и времени
        if let i = args.firstIndex(of: "--prefetch"), args.count > i + 1 {
            let rest = args.dropFirst(i + 2).compactMap { Int($0) }
            exit(PrefetchCLI.run(book: args[i + 1], from: rest.first ?? 0, count: rest.dropFirst().first ?? 6))
        }
        //   ScanReader --background-test <книга> [упреждение] — читатель открыл стр. 1 и ушёл:
        //   печать хода фоновой обработки до конца книги (или 120 с)
        if let i = args.firstIndex(of: "--background-test"), args.count > i + 1 {
            let ahead = args.count > i + 2 ? Int(args[i + 2]) ?? 1 : 1
            exit(MainActor.assumeIsolated { BackgroundCLI.run(book: args[i + 1], lookahead: ahead) })
        }
        //   ScanReader --translate <книга> <страница с 1> [язык] [вывод.png] — перевод страницы (печать абзацев
        //   и, если задан вывод, рендер переведённой страницы)
        if let i = args.firstIndex(of: "--translate"), args.count > i + 2 {
            exit(TranslateCLI.run(book: args[i + 1], page: (Int(args[i + 2]) ?? 1) - 1,
                                  target: args.count > i + 3 ? args[i + 3] : "ru",
                                  output: args.count > i + 4 ? args[i + 4] : nil))
        }
        //   ScanReader --import-apple-books --dry-run          — что будет импортировано (только числа)
        //   ScanReader --import-apple-books --to <папка>       — копирование своих PDF/EPUB
        if args.contains("--import-apple-books") {
            exit(AppleBooksCLI.run(dryRun: args.contains("--dry-run"),
                                   to: args.firstIndex(of: "--to").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil },
                                   list: args.contains("--list")))
        }
        // каждая книга — в своём окне, без системных вкладок (как в Apple Books)
        NSWindow.allowsAutomaticWindowTabbing = false
        Product.migrate()
        // по HIG — тонкие оверлейные полосы, появляются при прокрутке (и с мышью). Только если пользователь
        // не выбрал в Системных настройках «всегда»: registration domain уступает явной глобальной настройке.
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
        DispatchQueue.main.async { ApplicationUpdater.shared.start() }
        // миграция: масштаб, заданный до появления автоподбора, считаем ручным
        let d = UserDefaults.standard
        if d.object(forKey: "textScaleAuto") == nil, let old = d.object(forKey: "textScale") as? Double {
            d.set(abs(old - 1) < 0.001, forKey: "textScaleAuto")
        }
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        // при запуске — Библиотека; книги открываются в отдельных окнах читалки, как в Apple Books
        WindowGroup("Библиотека", id: "library") {
            LibraryRoot().frame(minWidth: 760, minHeight: 520).brandChrome()
        }
        WindowGroup(id: "reader", for: String.self) { $path in
            ReaderWindow(path: path ?? "").frame(minWidth: 720, minHeight: 520).brandChrome()
        }
        .windowStyle(.hiddenTitleBar)      // панель — капсулы в строке заголовка, фон окна = цвет темы
        Settings { SettingsView().brandChrome() }
        Window("О программе", id: "about") { AboutView().brandChrome() }
            .windowResizability(.contentSize)
            .commands { AppCommands() }
    }
}

/// Окно читалки: книга по пути (PDF, сканы, картинка; EPUB — отдельный просмотрщик).
struct ReaderWindow: View {
    let path: String
    @State private var book: BookModel?
    @State private var failed = false

    var body: some View {
        Group {
            if LibraryStore.kind(of: URL(fileURLWithPath: path)) == .epub {
                EPUBReaderView(url: URL(fileURLWithPath: path))
            } else if let book {
                ReaderView(book: book)
            } else if failed {
                Text("Не удалось открыть книгу: файл повреждён, пуст или защищён паролем").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(BookMetadata.display(for: URL(fileURLWithPath: path)).title)
        // окно закрыто — распознавание этой книги (упреждение, фон, идущие запросы Vision) прекращается
        .onDisappear { book?.close() }
        .task(id: path) {
            guard LibraryStore.kind(of: URL(fileURLWithPath: path)) != .epub else { return }
            book = BookModel(url: URL(fileURLWithPath: path))
            failed = book == nil
        }
    }
}

/// Рендер "чистой" страницы в PNG + JSON раскладки (для отладки и сравнения).
enum RenderCLI {
    static func run(input: String, output: String, themeName: String, scalePercent: Double = 100) -> Int32 {
        let url = URL(fileURLWithPath: input)
        guard let loaded = PageSource.load(url), let image = loaded.pages.first?.render() else {
            print("Не удалось открыть \(input)"); return 1
        }
        do {
            let start = Date()
            let page = try LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"]).analyze(image)
            print(String(format: "Анализ: %.2f с", Date().timeIntervalSince(start)))
            for p in page.layout.paragraphs {
                for l in p.lines {
                    let styled = l.words.filter { $0.bold || $0.italic }
                        .map { "\($0.text)\($0.bold ? "[B]" : "")\($0.italic ? "[I]" : "")" }
                    print("\(p.family.rawValue) \(Int(p.fontSize))px \(l.alignment.rawValue)\t\(l.text)  \(styled.joined(separator: " "))")
                }
            }
            print("Иллюстрации: \(page.layout.figures)\nЛинейки: \(page.layout.rules)")
            print("Надписей в иллюстрациях: \(page.layout.figureLabels.count)")
            for b in page.layout.codeBlocks {
                print("--- код (\(b.language.title)), шаг \(Int(b.pitch))px ---\n\(b.text)\n---")
            }

            let theme = ReaderTheme.named(themeName)
            let w = image.width, h = image.height
            let settings = ReflowSettings(scale: CGFloat(scalePercent / 100))
            if settings.reflows {
                let screens = Reflow.paginate(page.layout, palette: .original, ink: theme.ink, isDark: theme.isDark, settings: settings)
                print("Масштаб \(Int(scalePercent))%: экранных страниц \(screens.count)")
                for (k, sp) in screens.enumerated() {
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
                    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                    PageRenderer(palette: .original, theme: theme).draw(sp, of: page, in: ctx)
                    let url = URL(fileURLWithPath: output).deletingPathExtension().path + "-\(k + 1).png"
                    guard let out = ctx.makeImage(),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: String(url)) as CFURL,
                                                                     UTType.png.identifier as CFString, 1, nil) else { return 1 }
                    CGImageDestinationAddImage(dest, out, nil)
                    CGImageDestinationFinalize(dest)
                    print("Готово: \(url)")
                }
                return 0
            }
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)                        // y вниз, как в Canvas
            PageRenderer(palette: .original, theme: theme).draw(page, in: ctx)
            guard let out = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else { return 1 }
            CGImageDestinationAddImage(dest, out, nil)
            CGImageDestinationFinalize(dest)
            let json = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("json")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(page.layout).write(to: json)
            print("Готово: \(output)")
            return 0
        } catch {
            print("Ошибка: \(error)"); return 1
        }
    }
}

/// Прогон страниц книги через кеш (тот же путь, что и упреждение в читалке).
enum PrefetchCLI {
    static func run(book: String, from first: Int, count n: Int) -> Int32 {
        let url = URL(fileURLWithPath: book)
        guard let loaded = PageSource.load(url) else { print("Не удалось открыть \(book)"); return 1 }
        let languages = ["ru-RU", "en-US"]
        let cache = LayoutCache(bookURL: url, palette: .original, languages: languages)
        let analyzer = LayoutAnalyzer(palette: .original, languages: languages)
        print("Страниц: \(loaded.pages.count), кеш: \(cache.dir.path)")
        let range = max(0, first)..<min(loaded.pages.count, first + n)
        let total = Date()
        for i in range {
            let start = Date()
            do {
                let r = try LayoutCache.process(loaded.pages[i], index: i, cache: cache, analyzer: analyzer)
                print(String(format: "стр. %d: %@ за %.2f с, строк %d, иллюстраций %d, код %d", i + 1,
                             r.fromCache ? "из кеша" : "распознана", Date().timeIntervalSince(start),
                             r.page.layout.allLines.count, r.page.layout.figures.count, r.page.layout.codeBlocks.count))
            } catch {
                print("стр. \(i + 1): ошибка \(error)")
            }
        }
        print(String(format: "Всего: %.2f с", Date().timeIntervalSince(total)))
        return 0
    }
}

@MainActor
enum BackgroundCLI {
    static func run(book path: String, lookahead: Int) -> Int32 {
        guard let book = BookModel(url: URL(fileURLWithPath: path)) else { print("Не удалось открыть \(path)"); return 1 }
        book.lookahead = lookahead
        let start = Date()
        func t() -> String { String(format: "%5.1f с", Date().timeIntervalSince(start)) }
        print("\(t())  открыта, страниц \(book.count), в кеше \(book.cached.count), питание: \(BookModel.powerPauseReason() ?? "норма")")
        book.prefetch(visible: [0])
        var lastCached = -1, lastBg: Int?? = .none, lastPause: String?? = .none
        var flipped = false
        while Date().timeIntervalSince(start) < 120 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if book.cached.count != lastCached {
                lastCached = book.cached.count
                print("\(t())  распознано \(book.cached.count) из \(book.count), в памяти: \(book.pages.keys.sorted())")
            }
            if book.backgroundPage != lastBg { lastBg = book.backgroundPage; print("\(t())  фон: страница \(book.backgroundPage.map { String($0 + 1) } ?? "—")") }
            if book.backgroundPause != lastPause { lastPause = book.backgroundPause; if let p = book.backgroundPause { print("\(t())  пауза: \(p)") } }
            // имитация: читатель перелистнул, пока идёт фон — фон должен уступить и продолжить после простоя
            if !flipped, book.backgroundPage != nil, book.cached.count >= 3 {
                flipped = true
                print("\(t())  >>> листание на стр. 2")
                book.prefetch(visible: [1])
            }
            if book.cached.count == book.count, book.backgroundPage == nil { break }
        }
        print("\(t())  итог: \(book.cached.count) из \(book.count) в кеше")
        return book.cached.count == book.count ? 0 : 2
    }
}

enum TranslateCLI {
    static func run(book: String, page i: Int, target: String, output: String?) -> Int32 {
        let url = URL(fileURLWithPath: book)
        guard let loaded = PageSource.load(url), loaded.pages.indices.contains(i) else { print("Не удалось открыть \(book)"); return 1 }
        let languages = ["ru-RU", "en-US"]
        let cache = LayoutCache(bookURL: url, palette: .original, languages: languages)
        // раскладка из кеша рядом с книгой; нет — распознаём
        let layout0: PageLayout
        // для проверки годится и раскладка старой версии анализа (другая папка layouts-*)
        let side = Sidecar.dir(for: url)
        let old = ((try? FileManager.default.contentsOfDirectory(atPath: side.path)) ?? []).filter { $0.hasPrefix("layouts-") }
            .compactMap { SyncedFile.read(side.appendingPathComponent("\($0)/page-\(i).json")) }
            .compactMap { try? JSONDecoder().decode(PageLayout.self, from: $0) }.first
        if let l = cache.load(i) ?? old { layout0 = l } else {
            guard let r = try? LayoutCache.process(loaded.pages[i], index: i, cache: cache,
                                                   analyzer: LayoutAnalyzer(palette: .original, languages: languages)) else {
                print("Страница не распознана"); return 1
            }
            layout0 = r.page.layout
        }
        let units = PageText.units(layout0)
        var finished = false
        var result: Result<[String?], Error> = .failure(CancellationError())
        let t0 = Date()
        Task.detached {
            do { result = .success(try await TranslationRouter.translate(units, to: target)) } catch { result = .failure(error) }
            finished = true
        }
        // переводчик системы работает через главную очередь — крутим её, а не ждём семафор
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let tr: [String?]
        switch result {
        case .failure(let e): print("Ошибка: \(e.localizedDescription)"); return 2
        case .success(let t): tr = t
        }
        print(String(format: "Перевод за %.1f с, абзацев %d", Date().timeIntervalSince(t0), units.count))
        for (u, t) in zip(units, tr) { print("— \(u)\n→ \(t ?? "(без перевода)")\n") }
        guard let output else { return 0 }
        let layout = PageText.translatedLayout(layout0, tr)
        let theme = ReaderTheme.named("sepia")
        var settings = ReflowSettings(scale: 1.0001)
        var screens = Reflow.paginate(layout, palette: .original, ink: theme.ink, isDark: false, settings: settings)
        while screens.count > 1, settings.scale > 0.6 {
            settings.scale -= 0.04
            screens = Reflow.paginate(layout, palette: .original, ink: theme.ink, isDark: false, settings: settings)
        }
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(theme.paper); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var page = AnalyzedPage(scanOnly: ctx.makeImage()!)
        page.scanOnly = false
        page.layout = layout
        page.figureImages = layout.figures.map { _ in nil }
        PageRenderer(palette: .original, theme: theme).draw(screens[0], of: page, in: ctx)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        print(String(format: "Рендер: %@ (масштаб %.0f%%, экранов %d)", output, settings.scale * 100, screens.count))
        return 0
    }
}

enum AppleBooksCLI {
    static func run(dryRun: Bool, to: String?, list: Bool) -> Int32 {
        let scan = AppleBooksImporter.scan()
        let pdf = scan.importable.filter { $0.kind == "pdf" }.count
        print("База библиотеки Books: \(scan.libraryReadable ? "прочитана" : "недоступна")")
        print("Найдено книг: \(scan.items.count)")
        print("Можно импортировать: \(scan.importable.count) (PDF \(pdf), EPUB \(scan.importable.count - pdf))")
        print("Нельзя импортировать (DRM): \(scan.drm.count)")
        print("Нет доступа к файлу: \(scan.unavailable.count)")
        let withProgress = scan.items.filter { ($0.progress ?? 0) > 0 }.count
        print("С прогрессом чтения: \(withProgress)")
        if scan.collections.isEmpty {
            print("Коллекции: — \(scan.libraryReadable ? "" : "(хранятся в базе Books)")")
        } else {
            print("Коллекции:")
            for c in scan.collections { print("  \(c): \(scan.items.filter { $0.collections.contains(c) }.count)") }
        }
        for n in scan.notes { print("Примечание: \(n)") }
        if list {
            for i in scan.items { print("  [\(i.importable ? "+" : i.drmReason != nil ? "DRM" : "нет файла")] \(i.kind) \(i.title)") }
        }
        if dryRun { print("Пробный прогон: ничего не скопировано"); return 0 }
        guard let to else { print("Укажите --to <папка> или --dry-run"); return 1 }
        let r = AppleBooksImporter.importBooks(scan.importable, to: URL(fileURLWithPath: to))
        print("Скопировано: \(r.copied.count), ошибок: \(r.failed.count)")
        return r.failed.isEmpty ? 0 : 2
    }
}

/// Меню приложения: «О программе» со ссылкой поддержки и «Поддержать проект…».
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(TourCenter.russian ? "Ознакомительный тур" : "Welcome Tour") {
                // в окне книги — тур по книге, иначе — по библиотеке
                let inBook = NSApp.keyWindow?.identifier?.rawValue.hasPrefix("reader") ?? false
                TourCenter.shared.restart(in: inBook ? .book : .library)
            }
        }
        CommandGroup(replacing: .appInfo) {
            Button("О программе \(Product.name)") { openWindow(id: "about") }
            Divider()
            if ApplicationUpdater.shared.isConfigured {
                Button("Проверить обновления…") { ApplicationUpdater.shared.checkForUpdates() }
            }
            if SupportConfiguration.pageURL != nil {
                Button("Поддержать проект…") { _ = SupportConfiguration.open() }
            }
        }
    }
}

extension View {
    /// Айдентика и HIG: янтарный акцент вместо системного синего, без системных колец фокуса
    /// (клавиатурная навигация остаётся; выбранное обозначается своим стилем).
    func brandChrome() -> some View { tint(Brand.amber).focusEffectDisabled() }
}
