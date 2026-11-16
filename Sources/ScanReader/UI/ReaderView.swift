import SwiftUI

/// Позиция чтения: страница скана и экранная страница внутри неё (при масштабе ≠ 100% их может быть несколько).
struct ScreenPos: Hashable {
    var page: Int
    var sub: Int
}

/// Окно чтения как в Apple Books: фон окна = цвет темы, капсулы в строке заголовка,
/// разворот, стрелки по бокам, «N из M» под страницей.
struct ReaderView: View {
    @ObservedObject var book: BookModel

    @AppStorage("theme") private var themeName = ReaderTheme.calm.name
    @AppStorage("darkVariant") private var darkVariant = false
    @AppStorage("twoPages") fileprivate var twoPages = true
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("textScaleAuto") fileprivate var textScaleAuto = true
    @AppStorage("textScaleAutoValue") private var autoValue = 1.0
    @State private var containerSize: CGSize = .zero
    /// Действующий масштаб: ручной или подобранный под экран.
    private var scale: Double { textScaleAuto ? autoValue : TextScale.clamp(textScale) }
    @AppStorage("lineSpacing") private var lineSpacing = 1.0
    @AppStorage("margins") private var margins = 1.0
    @AppStorage("justify") private var justify = false
    @AppStorage("fontChoice") private var fontChoice = "theme"
    @AppStorage("enhanceFigures") fileprivate var enhanceFigures = true
    @AppStorage("enhanceScans") fileprivate var enhanceScans = true
    @AppStorage("languages") fileprivate var languagesCSV = "ru-RU,en-US"

    @State fileprivate var pos = ScreenPos(page: 0, sub: 0)
    @State private var showOriginal = false
    @State private var showTOC = false
    @State private var showNotes = false
    @State private var showAppearance = false
    @State private var showCustomize = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var searchStatus = ""
    @State fileprivate var bookmarks: Set<Int> = []
    @StateObject private var turner = PageTurner()
    @StateObject private var chrome = ChromeVisibility()

    private var theme: ReaderTheme {
        let t = ReaderTheme.named(themeName)
        return darkVariant ? t.darkVariant() : t
    }
    fileprivate var palette: FontPalette {
        switch fontChoice {
        case "original": return .original
        case "iowan": return .books
        case "charter": return .charter
        case "georgia": return .georgia
        default: return ReaderTheme.named(themeName).palette
        }
    }
    fileprivate var settings: ReflowSettings {
        ReflowSettings(scale: CGFloat(scale), lineSpacing: CGFloat(lineSpacing), margins: CGFloat(margins), justify: justify)
    }
    private var ink: Color { Color(cgColor: theme.ink) }
    @Environment(\.colorSchemeContrast) private var contrast
    /// «Увеличить контраст» в Универсальном доступе — вторичный текст цветом основного.
    private var secondary: Color { Color(cgColor: contrast == .increased ? theme.ink : theme.secondary) }
    /// Узкое окно — одна страница, даже если выбран разворот.
    private var spread: Bool { twoPages && (containerSize.width == 0 || containerSize.width >= 960) }

    // MARK: - экранные страницы

    private func count(_ page: Int) -> Int { max(1, book.screenCount(page, settings: settings) ?? 1) }

    private func advance(_ p: ScreenPos) -> ScreenPos? {
        if p.sub + 1 < count(p.page) { return ScreenPos(page: p.page, sub: p.sub + 1) }
        return p.page + 1 < book.count ? ScreenPos(page: p.page + 1, sub: 0) : nil
    }

    private func back(_ p: ScreenPos) -> ScreenPos? {
        if p.sub > 0 { return ScreenPos(page: p.page, sub: p.sub - 1) }
        return p.page > 0 ? ScreenPos(page: p.page - 1, sub: count(p.page - 1) - 1) : nil
    }

    private var visible: [ScreenPos] {
        // оригинал — это страница скана целиком: листаем по страницам скана, без экранных
        if showOriginal {
            let first = ScreenPos(page: pos.page, sub: 0)
            return spread && pos.page + 1 < book.count ? [first, ScreenPos(page: pos.page + 1, sub: 0)] : [first]
        }
        let first = ScreenPos(page: pos.page, sub: min(pos.sub, count(pos.page) - 1))
        if spread, let second = advance(first) { return [first, second] }
        return [first]
    }

    /// Номер экранной страницы по всей книге и их общее число.
    private func number(_ p: ScreenPos) -> (Int, Int) {
        var before = 0, total = 0
        for i in 0..<book.count {
            let c = count(i)
            if i < p.page { before += c }
            total += c
        }
        return (before + p.sub + 1, total)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(cgColor: theme.paper).ignoresSafeArea()
            HStack(alignment: .top, spacing: 64) {
                ForEach(visible, id: \.self) { p in
                    VStack(spacing: 12) {
                        PageView(book: book, index: p.page, sub: p.sub, theme: theme, settings: settings,
                                 showOriginal: showOriginal)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tourAnchor(p == visible[0] ? "book.page" : "book.page2")
                        // номер под каждой страницей разворота, как в Books
                        // тот же номер, что в меню/оглавлении/поиске (печатная метка PDF или индекс + 1);
                        // экранные страницы одной страницы скана — «14 · 2»
                        Text(p.sub > 0 ? "\(book.displayNumber(for: p.page)) · \(p.sub + 1)" : book.displayNumber(for: p.page))
                            .font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }
            }
            .offset(x: turner.offset)
            .opacity(turner.opacity)
            .padding(.top, 40).padding(.bottom, 14).padding(.horizontal, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { g in
                Color.clear.onAppear { turner.width = g.size.width; containerSize = g.size; updateAutoScale() }
                    .onChange(of: g.size) { turner.width = g.size.width; containerSize = g.size; updateAutoScale() }
            })
            .overlay(SwipeCatcher(onDelta: { turner.drag($0) },
                                  onEnd: { v in turner.endDrag(velocity: v) { turn($0) } })
                .allowsHitTesting(false))
            VStack(spacing: 1) {
                Text(book.title).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                backgroundProgress.opacity(chrome.visible ? 1 : 0)
            }
            .frame(maxWidth: 520).frame(height: TrafficLights.barHeight)
            HStack {
                navButton("chevron.left", key: .leftArrow) { turner.turn(-1) { turn(-1) } }.disabled(back(visible[0]) == nil)
                Spacer()
                navButton("chevron.right", key: .rightArrow) { turner.turn(1) { turn(1) } }.disabled(advance(visible.last!) == nil)
                    .tourAnchor("book.next")
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .opacity(chrome.visible ? 1 : 0)
            // полоса заголовка: перетаскивание окна и системный двойной клик (и при скрытой панели)
            TitleBarStrip().frame(height: TrafficLights.barHeight)
            topBar.noFocusRing().opacity(chrome.visible ? 1 : 0)
            ChromeTracker(chrome: chrome).allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            chrome.scheduleHide(after: 3)
            // позиция и закладки — из meta.json рядом с книгой (общие для всех устройств)
            let meta = Sidecar.meta(book.url)
            if let p = meta.position?.page, p < book.count { pos = ScreenPos(page: p, sub: 0) }
            bookmarks = Set(meta.bookmarks ?? [])
            book.palette = palette
            book.enhanceFigures = enhanceFigures
            book.enhanceScans = enhanceScans
            book.languages = languagesCSV.split(separator: ",").map(String.init)
            book.updateScreenCounts(settings)
            prefetch()
        }
        .modifier(SettingsObservers(reader: self))
        .sheet(isPresented: $showCustomize) { CustomizeSheet() }
        .tourOverlay(.book)
        .onAppear { TourCenter.shared.startIfNeeded(.book) }
        // пока идёт тур, панель не прячется — стрелкам есть на что указывать
        .onReceive(TourCenter.shared.$part) { p in pinChrome(p == .book) }
        .onChange(of: showTOC || showNotes || showAppearance || showSearch || showCustomize) { _, open in chrome.pinned = open }
    }

    // MARK: - панель в строке заголовка

    private var topBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 74, height: 1)       // место под «светофор»
            HStack(spacing: 2) {
                barButton("list.bullet", help: "Оглавление") { showTOC.toggle() }
                    .popover(isPresented: $showTOC, arrowEdge: .bottom) { tocView }
                barButton(twoPages ? "book.pages" : "rectangle.portrait", help: twoPages ? "Одна страница" : "Разворот") {
                    twoPages.toggle()
                }
                barButton("note.text", help: "Заметки и закладки") { showNotes.toggle() }
                    .tourAnchor("book.notes")
                    .popover(isPresented: $showNotes, arrowEdge: .bottom) { notesView }
                barButton("doc.viewfinder", help: "Показать оригинал скана", selected: showOriginal) {
                    showOriginal.toggle()
                }
                .tourAnchor("book.original")
                // страницы разворота: показывать сканом / распознать снова (сохраняется в meta.json)
                Menu {
                    ForEach(Array(Set(visible.map(\.page))).sorted(), id: \.self) { i in
                        Section("Страница \(book.displayNumber(for: i))") {
                            if book.showsScan(i) {
                                Button("Распознать заново") {
                                    if book.showScan.contains(i) { book.setShowScan(i, false) } else { book.showTextAnyway(i) }
                                }
                            } else {
                                Button("Показывать скан на этой странице") { book.setShowScan(i, true) }
                                Button("Распознать заново") { book.recognizeAgain(i) }
                            }
                            Toggle("Улучшать скан", isOn: Binding(get: { book.wantsEnhancedScan(i) },
                                                              set: { book.setScanEnhance(i, $0) }))
                                .disabled(!book.enhanceScans)
                        }
                    }
                } label: {
                    Image(systemName: "text.viewfinder").font(.system(size: 15)).frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(ink).help("Распознавание страниц разворота")
                .tourAnchor("book.pagemenu")
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .modifier(GlassCapsule())

            Spacer(minLength: 12)
            Color.clear.frame(width: 200, height: 30)      // клики проходят к полосе заголовка под панелью
            Spacer(minLength: 12)

            HStack(spacing: 2) {
                Button { showAppearance.toggle() } label: {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text("A").font(.system(size: 12, weight: .medium))
                        Text("A").font(.system(size: 17, weight: .medium))
                    }
                    .frame(width: 36, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(ink)
                .help("Темы и настройки")
                .tourAnchor("book.aa")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    AppearancePopover { showAppearance = false; showCustomize = true }
                }
                barButton("magnifyingglass", help: "Поиск") { showSearch.toggle() }
                    .tourAnchor("book.search")
                    .keyboardShortcut("f")
                    .popover(isPresented: $showSearch, arrowEdge: .bottom) { searchView }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .modifier(GlassCapsule())

            Button {
                if bookmarks.contains(pos.page) { bookmarks.remove(pos.page) } else { bookmarks.insert(pos.page) }
            } label: {
                Image(systemName: bookmarks.contains(pos.page) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15)).frame(width: 36, height: 36).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(ink)
            .modifier(GlassCircle())
            .help("Закладка")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func barButton(_ symbol: String, help: String, selected: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 36, height: 30)
                .background(Capsule().fill(selected ? ink.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(ink)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// «Распознано 120 из 340» — фоновая обработка книги в простое (кеш общий для всех устройств).
    @ViewBuilder
    private var backgroundProgress: some View {
        let done = book.cached.count
        if done < book.count {
            HStack(spacing: 4) {
                if let why = book.backgroundPause {
                    Image(systemName: "pause.circle")
                    Text("Распознано \(done) из \(book.count) · пауза: \(why)")
                } else {
                    ProgressView(value: Double(done), total: Double(max(book.count, 1)))
                        .progressViewStyle(.linear).frame(width: 60)
                    Text("Распознано \(done) из \(book.count)")
                }
            }
            .font(.system(size: 10)).foregroundStyle(ink.opacity(0.4))
            .help("Страницы распознаются в фоне, когда вы не листаете; результат сохраняется рядом с книгой")
        }
    }

    // MARK: - оглавление, закладки, поиск

    private var tocView: some View {
        List(0..<book.count, id: \.self) { i in
            Button {
                pos = ScreenPos(page: i, sub: 0)
                showTOC = false
            } label: {
                HStack {
                    Text(book.pages[i]?.layout.allLines.first?.text ?? "Страница \(book.displayNumber(for: i))").lineLimit(1)
                    Spacer()
                    Text(book.displayNumber(for: i)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 420)
    }

    /// «Заметки» как в Books: хайлайты (цвет, текст, заметка, страница) с переходом к месту и закладки.
    private var notesView: some View {
        let notes = book.annotations.items
        return VStack(alignment: .leading, spacing: 8) {
            Text("Заметки").font(.headline)
            if notes.isEmpty && bookmarks.isEmpty {
                Text("Выделите текст, чтобы добавить хайлайт или заметку").font(.callout).foregroundStyle(.secondary)
            }
            if !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes) { a in
                            if case .scan(let page, _, _) = a.anchor {
                                Button { pos = ScreenPos(page: page, sub: 0); showNotes = false } label: {
                                    NoteRow(annotation: a, location: "Стр. \(book.displayNumber(for: page))")
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Удалить хайлайт", role: .destructive) { book.annotations.delete(a.id) } }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            if !bookmarks.isEmpty {
                Divider()
                Text("Закладки").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(bookmarks.sorted(), id: \.self) { i in
                    Button("Страница \(book.displayNumber(for: i))") { pos = ScreenPos(page: i, sub: 0); showNotes = false }.buttonStyle(.link)
                }
            }
        }
        .padding(14).frame(width: 320, alignment: .leading)
    }

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск в книге", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit {
                    if let i = book.find(query, after: visible.last!.page) {
                        pos = ScreenPos(page: i, sub: 0)
                        searchStatus = "Страница \(book.displayNumber(for: i))"
                    } else {
                        searchStatus = "Не найдено среди распознанных страниц"
                    }
                }
            if !searchStatus.isEmpty { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
    }

    // MARK: - навигация

    private func navButton(_ symbol: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(ink.opacity(0.7))
                .frame(width: 44, height: 120)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .accessibilityLabel(symbol.contains("left") ? "Предыдущая страница" : "Следующая страница")
    }

    /// Автомасштаб: какой кегль основного текста скана сейчас на экране (pt) и сколько это физически.
    fileprivate func updateAutoScale() {
        guard textScaleAuto, let p = visible.first.flatMap({ book.pages[$0.page] }), !p.scanOnly else { return }
        let body = p.layout.paragraphs.max { $0.lines.count < $1.lines.count }
        guard let fontPx = body?.fontSize, containerSize.width > 100 else { return }
        let n = CGFloat(spread ? 2 : 1)
        // ширина страницы на экране: колонка разворота, ограниченная высотой по пропорции листа
        let byW = (containerSize.width - 64 * (n - 1)) / n
        let byH = (containerSize.height - 40) * p.layout.size.width / max(1, p.layout.size.height)
        let pageW = max(50, min(byW, byH))
        let bodyPt = fontPx * pageW / p.layout.size.width
        let ppi = TextScale.pointsPerInch(NSApp.keyWindow?.screen ?? NSScreen.main)
        let v = TextScale.auto(bodyPoints: bodyPt, pointsPerInch: ppi)
        if abs(v - autoValue) > 0.001 { autoValue = v }
    }

    private func pinChrome(_ tour: Bool) {
        chrome.pinned = tour || showTOC || showNotes || showAppearance || showSearch
    }

    /// Реакции на изменение настроек — отдельно, чтобы цепочка модификаторов не душила проверку типов.
    fileprivate struct SettingsObservers: ViewModifier {
        let reader: ReaderView
        func body(content: Content) -> some View {
            content
                .onChange(of: reader.pos) { reader.prefetch(); reader.saveProgress() }
                .onChange(of: reader.bookmarks) { let b = reader.bookmarks.sorted(); Sidecar.update(reader.book.url) { $0.bookmarks = b } }
                .onChange(of: reader.twoPages) { reader.prefetch() }
                .onChange(of: reader.settings) { reader.book.updateScreenCounts(reader.settings); reader.prefetch() }
                .onChange(of: reader.textScaleAuto) { reader.updateAutoScale() }
                .onChange(of: reader.book.pages.count) { reader.updateAutoScale() }
                .onChange(of: reader.palette) { reader.book.palette = reader.palette; reader.book.updateScreenCounts(reader.settings) }
                .onChange(of: reader.enhanceFigures) { reader.book.enhanceFigures = reader.enhanceFigures }
                .onChange(of: reader.enhanceScans) { reader.book.enhanceScans = reader.enhanceScans }
                .onChange(of: reader.languagesCSV) { reader.book.languages = reader.languagesCSV.split(separator: ",").map(String.init) }
        }
    }

    /// Перелистнуть и сказать, получилось ли (для анимации).
    private func turn(_ dir: Int) -> Bool {
        let before = pos
        go(dir)
        return pos != before
    }

    private func go(_ dir: Int) {
        if showOriginal {
            let step = spread ? 2 : 1
            let next = pos.page + dir * step
            if next >= 0, next < book.count { pos = ScreenPos(page: next, sub: 0) }
            else if dir < 0, pos.page > 0 { pos = ScreenPos(page: 0, sub: 0) }
            return
        }
        if dir > 0 {
            if let next = advance(visible.last!) { pos = next }
        } else {
            guard var p = back(visible[0]) else { return }
            if spread, let pp = back(p) { p = pp }
            pos = p
        }
    }

    fileprivate func saveProgress() {
        let last = visible.last!
        let (n, m) = number(last)
        LibraryStore.shared.recordReading(book.url, progress: Double(n) / Double(max(1, m)),
                                          position: ReadingPosition(page: pos.page))
    }

    /// Видимые страницы + упреждение на несколько страниц вперёд.
    fileprivate func prefetch() {
        var pages: [Int] = []
        for p in visible where !pages.contains(p.page) { pages.append(p.page) }
        book.prefetch(visible: pages)
    }
}

/// Капсула Liquid Glass (macOS 26+).
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View { content.glassEffect(.regular, in: .capsule) }
}

struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View { content.glassEffect(.regular, in: .circle) }
}

/// Перетаскивание окна за заголовок (строки заголовка нет — .hiddenTitleBar).
struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View { content.gesture(WindowDragGesture()) }
}
