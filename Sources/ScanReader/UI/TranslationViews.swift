import SwiftUI
import Translation

/// Панель «Перевод» в строке заголовка книги: показ перевода, язык, перевод всей книги в фоне.
struct TranslationPanel<T: BookTranslating>: View {
    @ObservedObject var translator: T
    @AppStorage("translateTarget") private var savedTarget = "ru"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Показывать перевод").font(.system(size: 13, weight: .semibold))
                    Text("Страницы переводятся по мере чтения").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("Показывать перевод", isOn: $translator.showing).toggleStyle(.switch).labelsHidden()
                    .controlSize(.small).focusable(false)
            }

            HStack {
                Text("Язык перевода").font(.system(size: 12))
                Spacer()
                Picker("Язык перевода", selection: Binding(get: { translator.target },
                                                           set: { translator.target = $0; savedTarget = $0 })) {
                    ForEach(TranslationTarget.all) { Text($0.title).tag($0.code) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().focusable(false)
            }

            if let p = translator.pendingDownload {
                VStack(alignment: .leading, spacing: 6) {
                    Label(p.localizedDescription, systemImage: "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Скачать языки") { translator.requestDownload() }.controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Вся книга").font(.system(size: 12, weight: .semibold))
                if translator.wholeBook {
                    ProgressView(value: Double(min(translator.doneCount, translator.totalCount)),
                                 total: Double(max(1, translator.totalCount)))
                        .progressViewStyle(.linear).tint(Brand.amber)
                    HStack {
                        Text(translator.progressLine)
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Остановить") { translator.stopBook() }.controlSize(.small)
                    }
                } else if translator.doneCount >= translator.totalCount {
                    Label("Книга переведена", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Brand.amberText(scheme))
                } else {
                    Button { translator.startBook(); translator.showing = true } label: {
                        Label("Перевести всю книгу", systemImage: "books.vertical")
                    }
                    .controlSize(.small)
                    Text("Перевод идёт в фоне и сохраняется рядом с книгой, поэтому через iCloud он появится и на других Mac."
                         + (translator.doneCount == 0 ? "" : " Уже переведено: \(translator.doneCount) из \(translator.totalCount)."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("Переводит системный переводчик Apple, текст не покидает Mac", systemImage: "lock")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Чтобы перевести фрагмент, выделите его", systemImage: "character.cursor.ibeam")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .noFocusRing()
    }
}

/// Плашка на странице, пока перевод готовится или не получился.
struct TranslationBadge: View {
    @ObservedObject var translator: Translator
    let index: Int
    let theme: ReaderTheme

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                if let p = translator.problems[index] {
                    Image(systemName: "exclamationmark.triangle")
                    Text(p.localizedDescription).lineLimit(2)
                    if case .needsDownload = p {
                        Button("Скачать") { translator.requestDownload() }.controlSize(.small)
                    } else {
                        Button("Повторить") { translator.retry(index) }.controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Перевожу страницу…")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(cgColor: theme.secondary))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 420)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .onAppear { translator.request(index) }
    }
}

/// Перевод выделенного фрагмента внутри меню выделения.
struct SnippetTranslation: View {
    let text: String
    let target: String
    @State private var result: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result {
                ScrollView {
                    Text(result).font(.system(size: 13, design: .serif)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(TranslationTarget(code: target).title).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(copied ? "Скопировано" : "Копировать перевод") { Pasteboard.copy(result); copied = true }
                        .controlSize(.small)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Перевожу…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            do {
                let t = try await Translator.translateSnippet(text, to: target)
                if t == text {
                    error = "Фрагмент уже на языке перевода (\(TranslationTarget(code: target).title.lowercased()))"
                } else { result = t }
            } catch let p as TranslationProblem {
                if case .needsDownload = p {
                    error = p.localizedDescription + ". Откройте «Перевод» на панели, чтобы скачать."
                } else { error = p.localizedDescription }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Скачивание языковых пакетов: системный диалог macOS (Translation.framework) по запросу переводчика.
struct TranslationDownloader<T: BookTranslating>: ViewModifier {
    @ObservedObject var translator: T

    func body(content: Content) -> some View {
        content.translationTask(translator.downloadConfig) { session in
            do { try await session.prepareTranslation() } catch {}
            await MainActor.run { translator.languagesInstalled() }
        }
    }
}
