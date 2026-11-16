import CryptoKit
import Foundation
import NaturalLanguage
import Translation

// MARK: - языки

/// Языки, на которые можно переводить: подписи по-русски, коды — как у Locale.Language.
struct TranslationTarget: Identifiable, Hashable {
    let code: String
    var id: String { code }
    var title: String {
        let name = Locale(identifier: "ru").localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Языки системного переводчика Apple (macOS 26) — их предлагаем в списке целевых.
    static let all: [TranslationTarget] = ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "pl", "nl", "tr",
                                           "ja", "zh", "ko", "ar", "hi", "id", "th", "vi", "sv", "da", "nb", "fi", "he"]
        .map(TranslationTarget.init)
}

enum LanguageGuess {
    /// Основной язык текста (код ISO 639-1: «ru», «en», «sr», «zh-Hans»…); nil — текста почти нет.
    static func detect(_ text: String, hint: String? = nil) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2 else { return nil }
        // короткие строки (заголовки, подписи) определяются ненадёжно — берём язык страницы
        if letters < 24, let hint { return hint }
        let r = NLLanguageRecognizer()
        // язык страницы — сильная подсказка: абзац «Глава 3. Хуки» иначе легко уходит в казахский
        if let hint { r.languageHints = [NLLanguage(hint): 0.85] }
        r.processString(text)
        guard let lang = r.dominantLanguage, lang != .undetermined else { return hint }
        if let hint, lang.rawValue != hint {
            // подписи на иллюстрациях, имена, короткие фразы — язык определяется плохо: считаем языком страницы
            if letters < 60 || (letters < 160 && !common.contains(base(lang.rawValue))) { return hint }
        }
        return lang.rawValue
    }

    /// Языки, которые встречаются в книгах часто; редкий язык в коротком абзаце — скорее ошибка определения.
    static let common: Set<String> = ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "pl", "nl", "sr", "hr", "bs", "cs",
                                      "sk", "sl", "bg", "be", "ja", "zh", "ko", "tr", "ar", "he", "el", "sv", "da", "nb", "fi"]

    /// Совпадают ли языки без учёта региона и письменности: «en-US» ~ «en», «zh-Hans» ~ «zh».
    static func same(_ a: String, _ b: String) -> Bool { base(a) == base(b) }

    static func base(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code)).lowercased()
    }

    static func title(_ code: String) -> String {
        let name = Locale(identifier: "ru").localizedString(forIdentifier: code)
            ?? Locale(identifier: "ru").localizedString(forLanguageCode: base(code)) ?? code
        return name
    }
}

// MARK: - ошибки

enum TranslationProblem: LocalizedError, Equatable {
    /// Пара поддерживается системным переводчиком, но языковые пакеты не скачаны.
    case needsDownload(source: String, target: String)
    /// Ни один из движков не умеет эту пару.
    case unsupported(source: String, target: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsDownload(let s, let t):
            return "Нужно скачать языки для перевода: \(LanguageGuess.title(s)) → \(LanguageGuess.title(t))"
        case .unsupported(let s, let t):
            return "Системный переводчик не знает пару \(LanguageGuess.title(s)) → \(LanguageGuess.title(t)). "
                + "Скачайте модель TranslateGemma в панели «Перевод»."
        case .failed(let m):
            return "Не удалось перевести: \(m)"
        }
    }
}

// MARK: - движки

/// Движок перевода: список абзацев одного языка → переводы в том же порядке.
protocol TranslationEngine: Sendable {
    var name: String { get }
    func canTranslate(from source: String, to target: String) async -> Bool
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String]
}

/// Системный переводчик Apple (Translation.framework): нейросетевой машинный перевод на устройстве.
actor AppleTranslator: TranslationEngine {
    static let shared = AppleTranslator()
    nonisolated let name = "Apple"
    private var sessions: [String: TranslationSession] = [:]

    func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    func canTranslate(from source: String, to target: String) async -> Bool {
        await status(from: source, to: target) == .installed
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        switch await status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslationProblem.needsDownload(source: source, target: target)
        default: throw TranslationProblem.unsupported(source: source, target: target)
        }
        let key = "\(source)>\(target)"
        let session = sessions[key] ?? TranslationSession(installedSource: Locale.Language(identifier: source),
                                                          target: Locale.Language(identifier: target))
        sessions[key] = session
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
        do {
            let responses = try await session.translations(from: requests)
            var out = texts
            for r in responses { if let id = r.clientIdentifier, let i = Int(id), out.indices.contains(i) { out[i] = r.targetText } }
            return out
        } catch {
            sessions[key] = nil
            if error is CancellationError { throw error }
            throw TranslationProblem.failed(error.localizedDescription)
        }
    }
}

/// Выбор движка: системный переводчик, если он знает пару; иначе локальная модель (если скачана).
enum TranslationRouter {
    static var fallback: (any TranslationEngine)? { LocalModelTranslator.shared.isInstalled ? LocalModelTranslator.shared : nil }

    /// Переводит абзацы: каждый — со своего языка; абзацы на целевом языке и без букв остаются как есть (nil).
    static func translate(_ texts: [String], to target: String, hint: String? = nil) async throws -> [String?] {
        var out = [String?](repeating: nil, count: texts.count)
        let page = hint ?? LanguageGuess.detect(texts.joined(separator: "\n"))
        var groups: [String: [Int]] = [:]
        for (i, t) in texts.enumerated() {
            guard let lang = LanguageGuess.detect(t, hint: page), !LanguageGuess.same(lang, target) else { continue }
            groups[lang, default: []].append(i)
        }
        for (lang, idx) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            try Task.checkCancellation()
            let batch = idx.map { texts[$0] }
            let result: [String]
            do {
                let apple = await AppleTranslator.shared.status(from: lang, to: target)
                if apple == .installed || apple == .supported || fallback == nil {
                    do {
                        result = try await AppleTranslator.shared.translate(batch, from: lang, to: target)
                    } catch TranslationProblem.unsupported(let s, let t) {
                        guard let f = fallback else { throw TranslationProblem.unsupported(source: s, target: t) }
                        result = try await f.translate(batch, from: lang, to: target)
                    }
                } else if let f = fallback {
                    result = try await f.translate(batch, from: lang, to: target)
                } else {
                    throw TranslationProblem.unsupported(source: lang, target: target)
                }
            } catch let p as TranslationProblem {
                // другой язык отдельных абзацев (нет пары, не скачаны языки) не мешает переводу страницы:
                // такие абзацы остаются в оригинале
                if let page, !LanguageGuess.same(lang, page) { continue }
                throw p
            }
            for (k, i) in idx.enumerated() where k < result.count { out[i] = result[k] }
        }
        return out
    }
}

// MARK: - текст страницы скана

/// Абзацы страницы скана как единицы перевода и обратная сборка раскладки из переводов.
enum PageText {
    /// Раскладка, из которой берутся абзацы: склеены абзацы, разорванные переносом. Без переносов через
    /// границу страниц — чтобы единицы перевода не зависели от того, распознаны ли соседи.
    static func prepared(_ layout: PageLayout) -> PageLayout {
        var l = Reflow.prepare(layout, carryIn: false, carryOut: nil)
        // OCR рвёт абзац посреди предложения (строка другой ширины, выделенное слово) — переводчику нужно
        // предложение целиком: склеиваем, если предыдущий кусок не закончен, а шрифт и кегль те же
        // пункты списка («•», «–», «1.») — отдельные единицы: OCR часто сливает их в один абзац
        var split: [Paragraph] = []
        for p in l.paragraphs {
            var cur = p
            cur.lines = []
            for line in p.lines {
                if !cur.lines.isEmpty, isListItem(line) { split.append(cur); cur.lines = [] }
                cur.lines.append(line)
            }
            split.append(cur)
        }
        var merged: [Paragraph] = []
        for p in split {
            if var prev = merged.last, !(p.lines.first.map(isListItem) ?? false), let a = prev.lines.last, let b = p.lines.first,
               prev.family == p.family, abs(prev.fontSize - p.fontSize) < max(prev.fontSize, 1) * 0.12,
               b.bounds.minY > a.bounds.minY, b.bounds.minY - a.bounds.maxY < a.bounds.height * 1.2,
               let last = a.words.last?.text.last, !".!?:;…»\")]".contains(last), a.words.count > 0 {
                prev.lines += p.lines
                merged[merged.count - 1] = prev
            } else {
                merged.append(p)
            }
        }
        l.paragraphs = merged
        return l
    }

    static func isListItem(_ line: TextLine) -> Bool {
        guard let w = line.words.first?.text else { return false }
        if ["•", "·", "▪", "◦", "–", "—", "-", "*"].contains(w) || w.hasPrefix("•") { return true }
        return w.count <= 3 && w.last.map { $0 == "." || $0 == ")" } == true && w.dropLast().allSatisfy(\.isNumber) && w.count > 1
    }

    /// Текст абзаца: строки через пробел, переносы склеены.
    static func text(_ p: Paragraph) -> String {
        var words: [String] = []
        let all = p.lines.flatMap(\.words).map(\.text)
        var i = 0
        while i < all.count {
            var w = all[i]
            while i + 1 < all.count, Dehyphen.isCandidate(w, all[i + 1]) {
                w = Dehyphen.join(w, all[i + 1]).text
                i += 1
            }
            words.append(w)
            i += 1
        }
        return words.joined(separator: " ")
    }

    static func units(_ layout: PageLayout) -> [String] { prepared(layout).paragraphs.map(text) }

    /// Отпечаток текста страницы: перевод в кеше годится, пока не изменилось распознавание.
    static func fingerprint(_ units: [String]) -> String {
        SHA256.hash(data: Data(units.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Раскладка с переведённым текстом: слова перевода раскладываются по исходным строкам абзаца
    /// (пропорционально длине), чтобы перекомпоновка сохранила кегль, интерлиньяж, выравнивание и отступ.
    static func translatedLayout(_ layout: PageLayout, _ translations: [String?]) -> PageLayout {
        var l = prepared(layout)
        for pi in l.paragraphs.indices {
            guard pi < translations.count, let t = translations[pi], !t.isEmpty else { continue }
            var p = l.paragraphs[pi]
            let src = p.lines.flatMap(\.words)
            let bold = src.filter(\.bold).count * 2 > src.count, italic = src.filter(\.italic).count * 2 > src.count
            let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
            let lengths = p.lines.map { max(1, $0.text.count) }
            let total = lengths.reduce(0, +)
            let chars = words.reduce(0) { $0 + $1.count + 1 }
            var lines: [TextLine] = []
            var wi = 0
            for (li, line) in p.lines.enumerated() {
                let last = li == p.lines.count - 1
                let share = last ? Int.max : Int((Double(lengths[li]) / Double(total) * Double(chars)).rounded())
                var used = 0
                var out: [Word] = []
                while wi < words.count, last || used < share || out.isEmpty {
                    var w = words[wi]
                    // дефис в конце строки склейка приняла бы за перенос
                    if !last, wi + 1 < words.count, used + w.count + 1 >= share, Dehyphen.marks.contains(w.last ?? " ") { w += "\u{2060}" }
                    out.append(Word(text: w, bounds: line.bounds, bold: bold, italic: italic))
                    used += w.count + 1
                    wi += 1
                    if wi >= words.count { break }
                }
                var nl = line
                nl.words = out
                nl.confidence = max(line.confidence, 1)    // фрагменты оригинала в переводе не нужны
                if !out.isEmpty { lines.append(nl) }
            }
            if lines.isEmpty { continue }
            // последняя строка — концовка абзаца: без выключки
            if lines.count > 1, p.lines.last?.alignment == .justify { lines[lines.count - 1].alignment = .left }
            p.lines = lines
            l.paragraphs[pi] = p
        }
        return l
    }
}

// MARK: - кеш переводов рядом с книгой

/// Переводы страниц: `.scanreader/<книга>/translations/<язык>/page-N.json` (синхронизируется через iCloud).
struct TranslationStore {
    struct Entry: Codable, Equatable {
        var source: String          // отпечаток исходного текста
        var units: [String?]        // nil — абзац уже на целевом языке
        var engine: String?
    }

    let dir: URL

    init(book: URL, target: String) {
        let fm = FileManager.default
        let side = Sidecar.dir(for: book).appendingPathComponent("translations/\(target)", isDirectory: true)
        if (try? fm.createDirectory(at: side, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: side.path) {
            dir = side
        } else {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let h = SHA256.hash(data: Data(book.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
            dir = base.appendingPathComponent("\(Product.dataFolder)/translations/\(book.lastPathComponent)-\(h)/\(target)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func url(_ key: String) -> URL { dir.appendingPathComponent("\(key).json") }

    func has(_ key: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url(key).path) || fm.fileExists(atPath: dir.appendingPathComponent(".\(key).json.icloud").path)
    }

    func load(_ key: String) -> Entry? {
        guard let d = SyncedFile.read(url(key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    func save(_ e: Entry, _ key: String) {
        if let d = try? JSONEncoder().encode(e) { SyncedFile.write(d, to: url(key)) }
    }

    /// Ключи готовых переводов (с любого устройства).
    func keys() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { n in
            if n.hasSuffix(".json.icloud"), n.hasPrefix(".") { return String(n.dropFirst().dropLast(12)) }
            return n.hasSuffix(".json") ? String(n.dropLast(5)) : nil
        })
    }
}
