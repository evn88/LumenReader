import AppKit
import Foundation

/// Склейка слов, перенесённых в оригинале («Единствен-» + «ное» → «Единственное»),
/// без поломки настоящих дефисных слов («что-то», «веб-приложений»). Решение — по словарю системы.
enum Dehyphen {
    /// Знаки переноса в конце строки: дефис, мягкий перенос, «‐».
    static let marks: Set<Character> = ["-", "\u{00AD}", "\u{2010}"]

    /// Частицы, которые всегда пишутся через дефис.
    private static let particles: Set<String> = ["то", "либо", "нибудь", "таки", "ка", "де", "с"]

    /// Строка заканчивается переносом, а следующая начинается со строчной — кандидат на склейку.
    static func isCandidate(_ left: String, _ right: String) -> Bool {
        guard left.count > 1, let h = left.last, marks.contains(h), let r = right.first else { return false }
        return r.isLowercase
    }

    /// Итоговое написание: склеенное слово или через дефис.
    static func join(_ left: String, _ right: String) -> (text: String, keptHyphen: Bool) {
        let stem = String(left.dropLast())
        let trail = right.reversed().prefix { $0.isPunctuation }.count
        let core = String(right.dropLast(trail))
        let joined = stem + core, hyphenated = stem + "-" + core
        let lang = (stem + core).unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? "ru" : "en"
        let coreLower = core.lowercased()

        if left.last == "\u{00AD}" { return (stem + right, false) }               // мягкий перенос — всегда перенос
        if particles.contains(coreLower) { return (stem + "-" + right, true) }       // что-то, кто-нибудь
        // словаря этого языка в системе нет — эвристика: короткая первая часть (веб-, IT-, арт-) — дефис
        guard hasDictionary(lang) else { return stem.count <= 4 ? (stem + "-" + right, true) : (stem + right, false) }
        if correct(joined, lang) { return (stem + right, false) }
        if correct(hyphenated, lang) { return (stem + "-" + right, true) }
        // оба куска — самостоятельные слова (веб + приложений): составное слово через дефис
        if correct(stem, lang), correct(core, lang), stem.count <= 6 { return (stem + "-" + right, true) }
        return (stem + right, false)
    }

    private static var dictionaryWorks: [String: Bool] = [:]

    /// Словарь языка есть и действительно работает: заведомая бессмыслица должна считаться ошибкой
    /// (на серверах без сессии пользователя проверка орфографии «пропускает» всё подряд).
    static func hasDictionary(_ lang: String) -> Bool {
        lock.lock()
        if let v = dictionaryWorks[lang] { lock.unlock(); return v }
        lock.unlock()
        let check = { () -> Bool in
            let c = NSSpellChecker.shared
            guard c.availableLanguages.contains(where: { $0.hasPrefix(lang) }) else { return false }
            let nonsense = lang == "ru" ? "ывапролджэ" : "qzxvbnmlkj"
            return c.checkSpelling(of: nonsense, startingAt: 0, language: lang, wrap: false,
                                   inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
        }
        let v = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        lock.lock(); dictionaryWorks[lang] = v; lock.unlock()
        return v
    }

    private static var memo: [String: Bool] = [:]
    private static let lock = NSLock()

    /// Слово есть в словаре системы для языка (NSSpellChecker — на главном потоке).
    static func correct(_ word: String, _ lang: String) -> Bool {
        let key = lang + ":" + word.lowercased()
        lock.lock()
        if let v = memo[key] { lock.unlock(); return v }
        lock.unlock()
        let check = {
            let c = NSSpellChecker.shared
            guard c.availableLanguages.contains(where: { $0.hasPrefix(lang) }) else { return true }
            return c.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                   inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let v = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        lock.lock(); memo[key] = v; lock.unlock()
        return v
    }
}
