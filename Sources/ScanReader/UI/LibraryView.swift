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
            Image(systemName: "books.vertical").font(.system(size: 56, weight: .thin)).foregroundStyle(.orange)
            Text("Выберите папку библиотеки").font(.title2.weight(.semibold))
            Text("""
                Здесь будут храниться книги, распознанный текст, улучшенные иллюстрации, обложки и прогресс чтения. \
                Выберите папку в iCloud Drive — тогда библиотека будет одинаковой на всех ваших устройствах, \
                а общую папку iCloud можно открыть и другим людям.
                """)
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Button("Выбрать папку…") { FolderPickerView.choose() }
                .buttonStyle(.borderedProminent).controlSize(.large)
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
                        Label(f.title, systemImage: f.symbol).tag(f)
                    }
                }
                Section("Мои коллекции") {
                    ForEach(store.collections, id: \.self) { c in
                        Label(c, systemImage: "list.bullet").tag(LibraryFilter.collection(c))
                    }
                    Button { newCollection = true } label: { Label("Новая коллекция", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            content
                .navigationTitle((filter ?? .all).title)
                .searchable(text: $query, placement: .toolbar, prompt: "Поиск")
                .toolbar { toolbar }
        }
        .dropDestination(for: URL.self) { urls, _ in store.importFiles(urls); return true }
        .sheet(isPresented: $showAppleBooks) { AppleBooksImportSheet() }
        .alert("Новая коллекция", isPresented: $newCollection) {
            TextField("Название", text: $newCollectionName)
            Button("Создать") { store.addCollection(newCollectionName); newCollectionName = "" }
            Button("Отмена", role: .cancel) { newCollectionName = "" }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.books.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "books.vertical").font(.system(size: 44, weight: .thin)).foregroundStyle(.secondary)
                Text(store.scanning ? "Читаю папку…" : "В библиотеке пока нет книг").foregroundStyle(.secondary)
                Text("Перетащите PDF, EPUB, сканы или папку со сканами сюда либо нажмите «Импорт».")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 28, alignment: .bottom)],
                          alignment: .leading, spacing: 30) {
                    ForEach(shown) { book in
                        BookCell(book: book, selected: selection == book.id)
                            .onTapGesture(count: 2) { open(book) }
                            .onTapGesture { selection = book.id }
                            .contextMenu { menu(book) }
                    }
                }
                .padding(28)
            }
            .focusable()
            .onKeyPress(.return) {
                if let b = shown.first(where: { $0.id == selection }) { open(b); return .handled }
                return .ignored
            }
        } else {
            List(shown, selection: $selection) { book in
                HStack(spacing: 12) {
                    CoverView(book: book).frame(width: 34, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).lineLimit(1)
                        Text(book.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(book.kind.rawValue.uppercased()).font(.caption2).foregroundStyle(.tertiary)
                    ProgressBadge(book: book).frame(width: 64, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(book) }
                .contextMenu { menu(book) }
            }
            .onKeyPress(.return) {
                if let b = shown.first(where: { $0.id == selection }) { open(b); return .handled }
                return .ignored
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Из Apple Books…") { showAppleBooks = true }
                Button("Файлы…") { chooseFiles() }
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
    @ObservedObject var store = LibraryStore.shared

    var body: some View {
        if let img = store.cover(for: book) ?? store.covers[book.id] {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 3)
        } else {
            // заглушка, пока строится обложка: цвет по названию + название
            let hue = Double(abs(book.title.hashValue % 360)) / 360
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.75),
                                              Color(hue: hue, saturation: 0.45, brightness: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .aspectRatio(0.7, contentMode: .fit)
                .overlay(Text(book.title).font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(.white).multilineTextAlignment(.center).padding(10))
                .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 3)
        }
    }
}

struct ProgressBadge: View {
    let book: LibraryBook
    var body: some View {
        if book.isNew {
            Text("НОВОЕ").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.blue))
        } else if book.finished {
            Text("ПРОЧИТАНО").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        } else if let p = book.progress {
            Text("\(Int((p * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct BookCell: View {
    let book: LibraryBook
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
                .frame(height: 210, alignment: .bottom)
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
            HStack(alignment: .firstTextBaseline) {
                Text(book.author ?? " ").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                ProgressBadge(book: book)
            }
        }
        .contentShape(Rectangle())
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
            if let url = SupportConfiguration.pageURL { DevelopmentSupportSection(pageURL: url) }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
