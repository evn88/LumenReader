import AppKit
import Foundation

/// Исправление типичных ошибок распознавания в словах (не в коде: там свой CodeFixer).
///
/// Только надёжные правки, без «догадок» языковой модели:
///  1. смешанные алфавиты в одном слове («кoт» с латинской o) — к алфавиту большинства;
///  2. цифры, похожие на буквы, внутри слова и буквы внутри чисел («1O5» → «105», «З7» → «37»);
///  3. слова, которых нет в словаре системы: подсказка проверки орфографии, если она отличается
///     от распознанного только похожими по начертанию буквами («колопка» → «колонка»).
enum OCRCorrector {
    // MARK: алфавиты

    /// Латинские буквы, неотличимые от кириллических по начертанию.
    static let latinToCyrillic: [Character: Character] = [
        "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х", "y": "у",
        "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М", "O": "О", "P": "Р", "T": "Т", "X": "Х",
    ]
    static let cyrillicToLatin: [Character: Character] = Dictionary(uniqueKeysWithValues: latinToCyrillic.map { ($1, $0) })

    static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
    static func isLatin(_ c: Character) -> Bool {
        c.isLetter && c.unicodeScalars.allSatisfy { $0.isASCII || (0x00C0...0x024F).contains($0.value) }
    }

    /// Буквы одного слова — в один алфавит (по большинству), если все «чужие» буквы имеют двойника.
    static func unifyScript(_ word: String) -> String {
        // слово может быть составным («SQL-запрос»): каждую буквенную часть отдельно
        var out = ""
        var run = ""
        func flush() { out += fixRun(run); run = "" }
        for ch in word {
            if ch.isLetter { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    private static func fixRun(_ run: String) -> String {
        let cyr = run.filter(isCyrillic).count, lat = run.filter(isLatin).count
        guard cyr > 0, lat > 0 else { return run }
        if cyr > lat, run.allSatisfy({ !isLatin($0) || latinToCyrillic[$0] != nil }) {
            return String(run.map { latinToCyrillic[$0] ?? $0 })
        }
        if lat > cyr, run.allSatisfy({ !isCyrillic($0) || cyrillicToLatin[$0] != nil }) {
            return String(run.map { cyrillicToLatin[$0] ?? $0 })
        }
        return run
    }

    // MARK: цифры и буквы

    /// Буквы, которые распознавание путает с цифрами (в числах).
    private static let digitLike: [Character: Character] = [
        "O": "0", "o": "0", "О": "0", "о": "0", "l": "1", "I": "1", "|": "1", "З": "3", "з": "3", "б": "6",
    ]

    /// Число с буквами-двойниками цифр («1O5», «l9», «З7») → цифры. Пунктуация по краям сохраняется.
    static func fixNumber(_ token: String) -> String {
        let lead = token.prefix { "([«\"".contains($0) }
        let trail = token.reversed().prefix { ".,;:)]»\"".contains($0) }
        let core = token.dropFirst(lead.count).dropLast(trail.count)
        guard core.count >= 2, core.count <= 6 else { return token }
        let digits = core.filter(\.isNumber).count
        guard digits >= 1, digits * 2 >= core.count, core.allSatisfy({ $0.isNumber || digitLike[$0] != nil }) else { return token }
        // «1O5» — да, но «IO», «lo» без цифр — нет (выше: хотя бы одна цифра)
        return lead + String(core.map { digitLike[$0] ?? $0 }) + String(trail.reversed())
    }

    /// Цифры внутри кириллического/латинского слова («П0ТОМ», «c0de»): замена подтверждается словарём.
    private static let letterLikeCyr: [Character: [Character]] = ["0": ["о", "О"], "3": ["з", "З"], "6": ["б"], "4": ["ч"]]
    private static let letterLikeLat: [Character: [Character]] = ["0": ["o", "O"], "1": ["l", "I"], "5": ["s", "S"]]

    // MARK: словарь

    /// Пары букв, похожих по начертанию (распознавание путает их чаще всего).
    private static let confusablePairs: [String] = [
        // кириллица
        "нп", "пл", "ин", "ип", "шщ", "цщ", "шп", "ес", "её", "ос", "ьъ", "ьб", "ъб", "тг", "кх", "лд", "жх", "ыь", "ия",
        "вз", "вб", "сб", "ае", "ао", "гп",
        // латиница
        "il", "lt", "li", "ij", "ce", "co", "ao", "ae", "nu", "nh", "hb", "vy", "uv", "rt", "fr", "ft", "ec", "oe", "mn",
        "IT", "IL", "OQ", "CG", "EF", "PR", "BR",
    ]
    private static let confusable: Set<String> = {
        var s = Set<String>()
        for p in confusablePairs {
            let a = Array(p)
            guard a.count == 2 else { continue }
            s.insert("\(a[0])\(a[1])"); s.insert("\(a[1])\(a[0])")
            let la = Character(String(a[0]).uppercased()), lb = Character(String(a[1]).uppercased())
            s.insert("\(la)\(lb)"); s.insert("\(lb)\(la)")
        }
        return s
    }()

    /// Цена правки: похожие буквы — 0.5, остальные замены, вставки и удаления — 1.
    static func visualDistance(_ a: String, _ b: String) -> (cost: Double, allConfusable: Bool) {
        let x = Array(a), y = Array(b)
        var d = [[Double]](repeating: [Double](repeating: 0, count: y.count + 1), count: x.count + 1)
        var plain = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = Double(i); plain[i][0] = i }
        for j in 0...y.count { d[0][j] = Double(j); plain[0][j] = j }
        if !x.isEmpty, !y.isEmpty {
            for i in 1...x.count {
                for j in 1...y.count {
                    let same = x[i - 1] == y[j - 1]
                    let conf = !same && confusable.contains("\(x[i - 1])\(y[j - 1])")
                    let sub = d[i - 1][j - 1] + (same ? 0 : conf ? 0.5 : 1)
                    let del = d[i - 1][j] + 1, ins = d[i][j - 1] + 1
                    if sub <= del, sub <= ins {
                        d[i][j] = sub; plain[i][j] = plain[i - 1][j - 1] + (same || conf ? 0 : 1)
                    } else if del <= ins {
                        d[i][j] = del; plain[i][j] = plain[i - 1][j] + 1
                    } else {
                        d[i][j] = ins; plain[i][j] = plain[i][j - 1] + 1
                    }
                }
            }
        }
        return (d[x.count][y.count], plain[x.count][y.count] == 0)
    }

    /// Языки проверки орфографии по языкам распознавания: на алфавит — ровно один язык,
    /// иначе (русский + сербский) по словарю не исправляем — можно «исправить» слово чужого языка.
    static func dictionaryLanguages(_ languages: [String]) -> (cyrillic: String?, latin: String?) {
        let codes = Set(languages.map { String($0.prefix(2)).lowercased() })
        let cyrillicLangs = codes.intersection(["ru", "uk", "be", "bg", "sr", "mk", "kk"])
        // пустой список — автоопределение: по умолчанию читалка распознаёт русский и английский
        let latinLangs = codes.subtracting(["ru", "uk", "be", "bg", "mk", "kk", "zh", "ja", "ko", "ar", "he", "th", "el"])
        return (codes.isEmpty ? "ru" : cyrillicLangs.count == 1 ? cyrillicLangs.first : nil,
                codes.isEmpty ? "en" : latinLangs.count == 1 ? latinLangs.first : nil)
    }

    /// Ближайшая по начертанию подсказка словаря для слова, которого в словаре нет.
    static func dictionaryFix(_ word: String, lang: String) -> String? {
        let core = word.trimmingCharacters(in: .punctuationCharacters)
        guard core.count >= 4, core.allSatisfy(\.isLetter), Dehyphen.hasDictionary(lang),
              !Dehyphen.correct(core, lang) else { return nil }
        // аббревиатуры и имена собственные посреди фразы не трогаем: только строчные или с заглавной первой
        let rest = core.dropFirst()
        guard rest.allSatisfy({ $0.isLowercase }) else { return nil }
        let guesses = Self.guesses(core, lang)
        // подсказки упорядочены по вероятности: из равных по цене берём первую
        var best: (String, Double)?
        for g in guesses where g.count >= core.count - 1 && g.count <= core.count + 1 && !g.contains(" ") {
            // регистр первой буквы — как в оригинале
            var cand = g
            if let f = core.first, f.isUppercase { cand = cand.prefix(1).uppercased() + cand.dropFirst() }
            let (cost, conf) = visualDistance(core, cand)
            // все правки — похожие буквы (не больше двух), либо одна любая в длинном слове
            guard (conf && cost <= 1.0) || (cost <= 1.0 && core.count >= 8 && cand.count == core.count) else { continue }
            if best == nil || cost < best!.1 { best = (cand, cost) }
        }
        guard let fixed = best?.0 else { return nil }
        return word.replacingOccurrences(of: core, with: fixed)
    }

    private static var guessMemo: [String: [String]] = [:]
    private static let lock = NSLock()

    private static func guesses(_ word: String, _ lang: String) -> [String] {
        let key = lang + ":" + word
        lock.lock()
        if let v = guessMemo[key] { lock.unlock(); return v }
        lock.unlock()
        let run = { () -> [String] in
            NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word,
                                          language: lang, inSpellDocumentWithTag: 0) ?? []
        }
        let v = Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        lock.lock(); guessMemo[key] = v; lock.unlock()
        return v
    }

    // MARK: слово и строка

    /// Слово целиком: алфавит, цифры/буквы, словарь.
    static func correct(_ word: String, languages: [String], useDictionary: Bool = true) -> String {
        var w = unifyScript(word)
        w = fixNumber(w)
        let letters = w.filter(\.isLetter)
        let cyr = letters.filter(isCyrillic).count, lat = letters.filter(isLatin).count
        let langs = dictionaryLanguages(languages)
        let lang = cyr > 0 && lat == 0 ? langs.cyrillic : lat > 0 && cyr == 0 ? langs.latin : nil
        // одна цифра внутри слова из букв
        let digits = w.filter(\.isNumber)
        if digits.count == 1, letters.count >= 3, let lang, useDictionary, let d = digits.first,
           let options = (cyr > 0 ? letterLikeCyr : letterLikeLat)[d] {
            for o in options {
                let cand = w.replacingOccurrences(of: String(d), with: String(o))
                let core = cand.trimmingCharacters(in: .punctuationCharacters)
                if core.allSatisfy(\.isLetter), Dehyphen.hasDictionary(lang), Dehyphen.correct(core, lang) { w = cand; break }
            }
        }
        if useDictionary, let lang, let fixed = dictionaryFix(w, lang: lang) { w = fixed }
        return w
    }

    static func correct(_ lines: inout [TextLine], languages: [String], useDictionary: Bool = true) {
        for li in lines.indices {
            for wi in lines[li].words.indices {
                let w = lines[li].words[wi].text
                let fixed = correct(w, languages: languages, useDictionary: useDictionary)
                if fixed != w { lines[li].words[wi].text = fixed }
            }
        }
    }
}
