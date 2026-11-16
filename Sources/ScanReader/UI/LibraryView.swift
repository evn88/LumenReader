import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Разделы сайдбара — как в Apple Books.
enum LibraryFilter: Hashable {
    case all, reading, finished, pdf, epub, scans
    case collection(String)

    var title: String {
        switch self {
        case .all: return "Все"
        case .reading: return "Читаю сейчас"
        case .finished: return "Прочитано"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .scans: return "Сканы"
        case .collection(let c): return c
        }
    }

    var symbol: String {
        switch self {
        case .all: return "books.vertical"
        case .reading: return "book"
        case .finished: return "checkmark.circle"
        case .pdf: return "doc.richtext"
        case .epub: return "book.closed"
        case .scans: return "doc.viewfinder"
        case .collection: return "list.bullet"
        }
    }

    func matches(_ b: LibraryBook) -> Bool {
        switch self {
        case .all: return true
        case .reading: return (b.progress ?? 0) > 0 && !b.finished
        case .finished: return b.finished
        case .pdf: return b.kind == .pdf
        case .epub: return b.kind == .epub
        case .scans: return b.recognized || b.kind == .scans || b.kind == .image
        case .collection(let c): return b.collections.contains(c)
        }
    }
}

enum LibrarySort: String, CaseIterable {
    case recent = "Недавние", title = "Название", author = "Автор"
}

/// Корень окна библиотеки: выбор папки при первом запуске, иначе — библиотека.
struct LibraryRoot: View {
    @ObservedObject var store = LibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false

    var body: some View {
        Group {
            if store.folder == nil {
                FolderPickerView()
            } else {
                LibraryView()
            }
        }
        .onAppear {
            // разработка: ScanReader --open <книга> — сразу открыть окно читалки (без флага — только Библиотека)
            let args = CommandLine.arguments
            if !opened, let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                opened = true
                openWindow(id: "reader", value: URL(fileURLWithPath: args[i + 1]).standardizedFileURL.path)
            }
        }
    }
}

struct FolderPickerView: View {
    var body: some View {
        VStack(spacing: 18) {
            LampIllustration().frame(width: 160, height: 140)
            Text("Выберите папку библиотеки").font(.system(.title2, design: .serif).weight(.semibold))
            Text("""
                Здесь будут храниться книги, распознанный текст, улучшенные иллюстрации, обложки и прогресс чтения. \
                Выберите папку в iCloud Drive — тогда библиотека будет одинаковой на всех ваших устройствах, \
                а общую папку iCloud можно открыть и другим людям.
                """)
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Button("Выбрать папку…") { FolderPickerView.choose() }
                .buttonStyle(.borderedProminent).tint(Brand.amber).foregroundStyle(.black).controlSize(.large)
            Text("Папку можно сменить позже в Настройках (⌘,)").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка библиотеки \(Product.name) (лучше в iCloud Drive)"
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { panel.directoryURL = iCloud }
        if panel.runModal() == .OK, let url = panel.url { LibraryStore.shared.open(url) }
    }
}

struct LibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("libraryGrid") private var grid = true
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue
    @State private var filter: LibraryFilter? = .all
    @State private var query = ""
    @State private var selection: LibraryBook.ID?
    @State private var showAppleBooks = false
    @State private var newCollection = false
    @State private var newCollectionName = ""
    @Environment(\.colorScheme) private var scheme
    @State private var dropCount: Int?
    @State private var dropCollection: String?

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }

    private var shown: [LibraryBook] {
        var list = store.books.filter { (filter ?? .all).matches($0) }
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.author ?? "").localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .recent: list.sort { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending }
        }
        return list
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("Библиотека") {
                    ForEach([LibraryFilter.all, .reading, .finished, .pdf, .epub, .scans], id: \.self) { f in
                        SidebarRow(title: f.title, symbol: f.symbol, count: store.books.filter(f.matches).count).tag(f)
                    }
                }
                Section("Мои коллекции") {
                    ForEach(store.collections, id: \.self) { c in
                        SidebarRow(title: c, symbol: "books.vertical", count: store.books.filter { $0.collections.contains(c) }.count)
                            .tag(LibraryFilter.collection(c))
                            // сброс на коллекцию — книги сразу в неё
                            .onDrop(of: [.fileURL], delegate: CollectionDrop(inner: BookDropDelegate(dropCount: $dropCount, collection: c, store: store),
                                                                             name: c, target: $dropCollection))
                    }
                    Button { newCollection = true } label: { Label("Новая коллекция", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Новая коллекция")
                }
            }
            // системный материал сайдбара во всю высоту окна (вместе со светофором), без своего фона
            .listStyle(.sidebar)
            .scrollIndicators(.automatic)
            .background(OverlayScrollers())
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .tourAnchor("library.sidebar")
        } detail: {
            content
                // тёплый фон под всё окно, включая область под прозрачным тулбаром:
                // сетка уходит под тулбар с системным scroll edge effect, без своей полосы
                .background(Brand.paper(scheme).ignoresSafeArea())
                .background(OverlayScrollers())
                .tourAnchor("library.grid")
                .navigationTitle((filter ?? .all).title)
                .searchable(text: $query, placement: .toolbar, prompt: "Поиск")
                .toolbar { toolbar }
        }
        .onDrop(of: [.fileURL], delegate: BookDropDelegate(dropCount: $dropCount, store: store))
        .overlay { if let n = dropCount { DropHighlight(count: n, collection: dropCollection) } }
        .overlay(alignment: .bottom) {
            if let p = store.importProgress { ImportProgressBadge(done: p.done, total: p.total) }
        }
        .animation(.easeOut(duration: 0.15), value: dropCount)
        .tourOverlay(.library)
        .onAppear { TourCenter.shared.startIfNeeded(.library) }
        .sheet(isPresented: $showAppleBooks) { AppleBooksImportSheet() }
        .alert("Новая коллекция", isPresented: $newCollection) {
            TextField("Название", text: $newCollectionName)
            Button("Создать") { store.addCollection(newCollectionName); newCollectionName = "" }
            Button("Отмена", role: .cancel) { newCollectionName = "" }
        }
    }

    /// «Продолжить чтение»: начатые и не дочитанные, последние открытые первыми.
    private var continueReading: [LibraryBook] {
        store.books.filter { ($0.progress ?? 0) > 0 && !$0.finished }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            .prefix(4).map { $0 }
    }

    @ViewBuilder
    private var content: some View {
        if store.books.isEmpty {
            EmptyLibraryView(scanning: store.scanning, importFiles: chooseFiles)
        } else if grid {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if (filter ?? .all) == .all, query.isEmpty, !continueReading.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "Продолжить чтение", subtitle: nil)
                            ContinueShelf(books: continueReading, open: open, menu: { AnyView(menu($0)) })
                                .padding(.horizontal, -32)        // лента — до краёв окна
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: (filter ?? .all).title, subtitle: countText(shown.count))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 152, maximum: 184), spacing: 24, alignment: .bottom)],
                                  alignment: .leading, spacing: 32) {
                            ForEach(shown) { book in
                                BookCell(book: book, selected: selection == book.id)
                                    .onTapGesture(count: 2) { open(book) }
                                    .onTapGesture { selection = book.id }
                                    .contextMenu { menu(book) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { open(book) }
                            }
                        }
                    }
                }
                .padding(32)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                if let b = shown.first(where: { $0.id == selection }) { open(b); return .handled }
                return .ignored
            }
        } else {
            List(shown, selection: $selection) { book in
                HStack(spacing: 12) {
                    CoverView(book: book).frame(width: 32, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).lineLimit(1)
                        Text(book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(book.kind.rawValue.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    ProgressBadge(book: book).frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(book) }
                .contextMenu { menu(book) }
            }
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                if let b = shown.first(where: { $0.id == selection }) { open(b); return .handled }
                return .ignored
            }
        }
    }

    private func countText(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = m10 == 1 && m100 != 11 ? "книга" : (2...4).contains(m10) && !(12...14).contains(m100) ? "книги" : "книг"
        return "\(n) \(w)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Из Apple Books…") { showAppleBooks = true }
                Button("Файлы…") { chooseFiles() }.keyboardShortcut("o")
            } label: { Label("Импорт", systemImage: "square.and.arrow.down") }
                .help("Импорт книг в библиотеку")
            Menu {
                Picker("Сортировка", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: { Label("Сортировка", systemImage: "arrow.up.arrow.down") }
            Picker("Вид", selection: $grid) {
                Image(systemName: "square.grid.2x2").tag(true)
                Image(systemName: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .help("Сетка / список")
        }
    }

    @ViewBuilder
    private func menu(_ book: LibraryBook) -> some View {
        Button("Открыть") { open(book) }
        Menu("Коллекции") {
            ForEach(store.collections, id: \.self) { c in
                Button { store.toggle(book, in: c) } label: {
                    if book.collections.contains(c) { Label(c, systemImage: "checkmark") } else { Text(c) }
                }
            }
            Divider()
            Button("Новая коллекция…") { newCollection = true }
        }
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
    }

    private func open(_ book: LibraryBook) {
        selection = book.id
        openWindow(id: "reader", value: book.url.path)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .epub, .image, .folder]
        panel.prompt = "Импортировать"
        if panel.runModal() == .OK { store.importFiles(panel.urls) }
    }
}

struct CoverView: View {
    let book: LibraryBook
    var glow = false
    @ObservedObject var store = LibraryStore.shared

    var body: some View {
        Group {
            if let img = store.cover(for: book) ?? store.covers[book.id] {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                // заглушка, пока строится обложка: тёплый тон по названию + название
                let hue = 0.05 + Double(abs(book.title.hashValue % 100)) / 1000
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.72),
                                                  Color(hue: hue, saturation: 0.55, brightness: 0.48)],
                                         startPoint: .top, endPoint: .bottom))
                    .aspectRatio(0.7, contentMode: .fit)
                    .overlay(Text(book.title).font(.system(size: 12, weight: .semibold, design: .serif))
                        .foregroundStyle(.white).multilineTextAlignment(.center).padding(10))
            }
        }
        // мягкий свет лампы под обложкой
        .shadow(color: glow ? Brand.amber.opacity(0.45) : .black.opacity(0.22), radius: glow ? 22 : 5, x: 0, y: glow ? 10 : 3)
        .accessibilityHidden(true)
    }
}

struct ProgressBadge: View {
    let book: LibraryBook
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if book.isNew {
            Text("НОВОЕ").font(.caption2.weight(.bold)).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Brand.amber))
                .accessibilityLabel("Новая книга")
        } else if book.finished {
            Label("Прочитано", systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        } else if let p = book.progress {
            Text("\(Int((p * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(Brand.amberText(scheme))
                .accessibilityLabel("Прочитано \(Int((p * 100).rounded())) процентов")
        }
    }
}

struct BookCell: View {
    let book: LibraryBook
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(book: book)
                .frame(height: 216, alignment: .bottom)
                .frame(maxWidth: .infinity)
                .scaleEffect(hover ? 1.02 : 1, anchor: .bottom)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Brand.amber.opacity(0.22) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Brand.amber.opacity(0.8) : .clear, lineWidth: 1.5))
            Text(book.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack(alignment: .firstTextBaseline) {
                Text(book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityHidden(book.author == nil)
                Spacer(minLength: 4)
                ProgressBadge(book: book)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Крупная карточка «Продолжить чтение»: обложка со свечением, название, полоса прогресса.
struct ContinueCard: View {
    let book: LibraryBook
    var open: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: open) {
            HStack(alignment: .bottom, spacing: 16) {
                CoverView(book: book, glow: true).frame(width: 112, height: 160, alignment: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text(BookMetadata.unbreakableWords(book.title)).font(.system(.title3, design: .serif).weight(.semibold))
                        .lineLimit(2).truncationMode(.tail)
                    if let a = book.author { Text(a).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    ProgressView(value: book.progress ?? 0).tint(Brand.amber).frame(width: 136)
                    Text("Прочитано \(Int(((book.progress ?? 0) * 100).rounded()))%").font(.caption)
                        .foregroundStyle(Brand.amberText(scheme))
                }
                .frame(width: 152, height: 160, alignment: .topLeading)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(book.title), прочитано \(Int(((book.progress ?? 0) * 100).rounded())) процентов")
        .accessibilityHint("Открыть книгу")
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(.title, design: .serif).weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    @Environment(\.colorScheme) private var scheme
    /// Выбранная строка в активном окне: текст и иконка — белые на акценте (HIG), а не янтарь на янтаре.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 20, alignment: .center)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Brand.amberText(scheme)))
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)").font(.callout.monospacedDigit())
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Тонкие оверлейные полосы прокрутки (появляются при прокрутке, колонку не занимают).
/// Если в Системных настройках выбрано «Показывать полосы прокрутки: всегда», не трогаем.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            token.map(NotificationCenter.default.removeObserver)
            token = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
                // AppKit переключает стиль сам после уведомления — применяем следом
                DispatchQueue.main.async { self?.apply() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }
        func apply() {
            guard let root = window?.contentView else { return }
            let always = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleShowScrollBars") == "Always"
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView {
                    if always {
                        // «Всегда»: системный стиль, но без серой колонки под полосой — фон окна виден насквозь
                        sv.drawsBackground = false
                        sv.verticalScroller?.wantsLayer = true
                        sv.verticalScroller?.layer?.backgroundColor = .clear
                    } else if sv.scrollerStyle != .overlay {
                        sv.scrollerStyle = .overlay; sv.autohidesScrollers = true
                    }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { DispatchQueue.main.async { v.apply() } }
}

/// Пустая библиотека: лампа над раскрытой книгой.
struct EmptyLibraryView: View {
    let scanning: Bool
    var importFiles: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            LampIllustration().frame(width: 160, height: 140)
            Text(scanning ? "Читаю папку…" : "Здесь будет светло от книг").font(.system(.title2, design: .serif).weight(.semibold))
            Text("Перетащите PDF, EPUB, сканы или папку со сканами в окно — или импортируйте их.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Импортировать файлы…", action: importFiles).buttonStyle(.borderedProminent).tint(Brand.amber)
                .foregroundStyle(.black).controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LampIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Brand.amber.opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: 80))
                .offset(y: 18)
            Image(systemName: "lamp.desk.fill").font(.system(size: 54)).foregroundStyle(Brand.amber).offset(x: 34, y: -34)
            Image(systemName: "book").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary).offset(y: 34)
        }
        .accessibilityHidden(true)
    }
}

/// Лист «Импорт из Apple Books»: сводка, выбор книг, прогресс копирования, объяснение про доступ к диску.
struct AppleBooksImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store = LibraryStore.shared
    @State private var scan: AppleBooksScan?
    @State private var chosen: Set<String> = []
    @State private var copying = false
    @State private var done = 0
    @State private var failed = 0
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Импорт из Apple Books").font(.title3.weight(.semibold))
            if let scan {
                if !scan.libraryReadable { accessBox }
                HStack(spacing: 18) {
                    stat("Найдено", scan.items.count)
                    stat("Можно импортировать", scan.importable.count)
                    stat("С DRM", scan.drm.count)
                    stat("Коллекции", scan.collections.count)
                }
                if !scan.collections.isEmpty {
                    Text("Коллекции: " + scan.collections.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                List {
                    Section {
                        ForEach(scan.importable, id: \.sourcePath) { item in
                            Toggle(isOn: Binding(get: { chosen.contains(item.sourcePath!) },
                                                 set: { if $0 { chosen.insert(item.sourcePath!) } else { chosen.remove(item.sourcePath!) } })) {
                                HStack {
                                    Text(item.title).lineLimit(1)
                                    Spacer()
                                    Text(item.kind.uppercased()).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Свои книги")
                            Spacer()
                            Button("Все") { chosen = Set(scan.importable.compactMap(\.sourcePath)) }.buttonStyle(.link)
                            Button("Ничего") { chosen = [] }.buttonStyle(.link)
                        }
                    }
                    if !scan.drm.isEmpty {
                        Section("Нельзя импортировать (DRM)") {
                            ForEach(scan.drm, id: \.title) { Text($0.title).foregroundStyle(.secondary) }
                        }
                    }
                }
                .frame(minHeight: 240)
                if copying || finished {
                    ProgressView(value: Double(done + failed), total: Double(max(1, chosen.count))) {
                        Text(finished ? "Готово: импортировано \(done)" + (failed > 0 ? ", ошибок \(failed)" : "")
                                      : "Копирую \(done + failed + 1) из \(chosen.count)…").font(.caption)
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Читаю библиотеку Books…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                if let folder = store.folder {
                    Text("В папку: \(folder.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Закрыть" : "Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                if !finished {
                    Button("Импортировать (\(chosen.count))") { start() }
                        .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty || copying)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .task {
            let s = await Task.detached { AppleBooksImporter.scan() }.value
            scan = s
            chosen = Set(s.importable.compactMap(\.sourcePath))
        }
    }

    private var accessBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Нужен полный доступ к диску", systemImage: "lock.shield").font(.headline)
            Text("""
                macOS не даёт прочитать библиотеку Apple Books: коллекции, прогресс и купленные книги. \
                Без доступа доступны только ваши PDF и EPUB из iCloud Books. Включите \(Product.name) в \
                «Конфиденциальность и безопасность → Полный доступ к диску» (кнопка «+» → выберите приложение) \
                и перезапустите его.
                """).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Bundle.main.bundlePath).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Button("Открыть настройки") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start() {
        guard let scan, let folder = store.folder else { return }
        let items = scan.importable.filter { chosen.contains($0.sourcePath!) }
        copying = true; done = 0; failed = 0
        Task.detached {
            for item in items {
                let ok = AppleBooksImporter.importOne(item, to: folder)
                await MainActor.run { if ok { done += 1 } else { failed += 1 } }
            }
            await MainActor.run { copying = false; finished = true; store.refresh() }
        }
    }
}

/// Настройки (⌘,): папка библиотеки.
struct SettingsView: View {
    @ObservedObject var store = LibraryStore.shared

    var body: some View {
        Form {
            LabeledContent("Папка библиотеки") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(store.folder?.path ?? "не выбрана").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Button("Сменить…") { FolderPickerView.choose() }
                }
            }
            Text("Лучше общая папка iCloud Drive: книги, распознанный текст, обложки и прогресс будут на всех устройствах.")
                .font(.caption).foregroundStyle(.secondary)
            if ApplicationUpdater.shared.isConfigured { UpdatesSection() }
            if let url = SupportConfiguration.pageURL { DevelopmentSupportSection(pageURL: url) }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

// MARK: - перетаскивание книг в окно

/// Приём файлов из Finder во всё окно библиотеки: подсветка (янтарная пунктирная рамка по углам окна,
/// затемнение, «Отпустите, чтобы добавить N книг»); неподдерживаемое — без подсветки и с курсором «нельзя».
struct BookDropDelegate: DropDelegate {
    @Binding var dropCount: Int?
    var collection: String? = nil
    var store: LibraryStore

    private func urls(_ info: DropInfo, _ done: @escaping ([URL]) -> Void) {
        let providers = info.itemProviders(for: [.fileURL])
        var result: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); result.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(result) }
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        urls(info) { u in
            let n = LibraryStore.importable(u).count
            dropCount = n > 0 ? n : nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dropCount == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) { dropCount = nil }

    func performDrop(info: DropInfo) -> Bool {
        let ok = dropCount != nil
        dropCount = nil
        guard ok else { return false }
        urls(info) { u in MainActor.assumeIsolated { store.importFiles(u, collection: collection) } }
        return true
    }
}

struct DropHighlight: View {
    let count: Int
    var collection: String? = nil

    private var text: String {
        let m10 = count % 10, m100 = count % 100
        let w = m10 == 1 && m100 != 11 ? "книгу" : (2...4).contains(m10) && !(12...14).contains(m100) ? "книги" : "книг"
        return collection.map { "Отпустите, чтобы добавить \(count) \(w) в «\($0)»" } ?? "Отпустите, чтобы добавить \(count) \(w)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.amber, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                .padding(10)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 36)).foregroundStyle(Brand.amber)
                Text(text).font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Индикатор импорта поверх окна.
struct ImportProgressBadge: View {
    let done: Int
    let total: Int
    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(1, total))).tint(Brand.amber).frame(width: 120)
            Text("Добавляю книги: \(done) из \(total)").font(.callout)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(16)
    }
}

/// Сброс на коллекцию: тот же приём, плюс подпись «…в «Коллекция»».
struct CollectionDrop: DropDelegate {
    var inner: BookDropDelegate
    let name: String
    @Binding var target: String?
    func validateDrop(info: DropInfo) -> Bool { inner.validateDrop(info: info) }
    func dropEntered(info: DropInfo) { target = name; inner.dropEntered(info: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { inner.dropUpdated(info: info) }
    func dropExited(info: DropInfo) { target = nil; inner.dropExited(info: info) }
    func performDrop(info: DropInfo) -> Bool { target = nil; return inner.performDrop(info: info) }
}

/// Лента «Продолжить чтение»: прокрутка до краёв окна, мягкий fade по краям, стрелки при наведении,
/// привязка к карточкам; свечение обложек не обрезается.
struct ContinueShelf: View {
    let books: [LibraryBook]
    var open: (LibraryBook) -> Void
    var menu: (LibraryBook) -> AnyView
    @State private var hover = false
    @State private var index = 0          // карточка у левого края (для стрелок)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(books) { book in
                        ContinueCard(book: book) { open(book) }.contextMenu { menu(book) }.id(book.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 28)                  // место для свечения сверху и снизу
            }
            .contentMargins(.horizontal, 32, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()                        // свечение затухает само, без прямых краёв
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 48)
                }
                .padding(.vertical, -40)
            }
            .overlay {
                if hover, books.count > 1 {
                    HStack {
                        arrow("chevron.left", label: "Назад") { go(-1, proxy) }.disabled(index == 0)
                        Spacer()
                        arrow("chevron.right", label: "Вперёд") { go(1, proxy) }.disabled(index >= books.count - 1)
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    private func go(_ d: Int, _ proxy: ScrollViewProxy) {
        index = min(max(0, index + d), books.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(books[index].id, anchor: .leading) }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
