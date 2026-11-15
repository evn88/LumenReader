import AppKit
import Foundation

/// Надёжность распознавания страницы: средняя уверенность OCR и доля «мусорных» слов
/// (нет в словаре системы для языка слова или буквы разных алфавитов внутри одного слова).
enum PageQuality {
    static let minMeanConfidence: Float = 0.45
    static let maxGarbageShare = 0.35

    /// Быстрая проверка без словаря (можно с любого потока).
    static func isUnreliableByConfidence(_ layout: PageLayout) -> Bool {
        let lines = layout.allLines
        guard !lines.isEmpty else { return false }
        return lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count) < minMeanConfidence
    }

    static func isUnreliable(_ layout: PageLayout) -> Bool {
        let lines = layout.allLines
        guard !lines.isEmpty else { return false }
        let mean = lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count)
        if mean < minMeanConfidence { return true }
        return garbageShare(lines.flatMap(\.words).map(\.text)) > maxGarbageShare
    }

    /// Доля подозрительных слов среди слов длиной ≥ 4 (проверяется не больше 120 слов).
    static func garbageShare(_ words: [String]) -> Double {
        let sample = words.map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { $0.count >= 4 && $0.allSatisfy { $0.isLetter || $0 == "-" } }
            .prefix(120)
        guard sample.count >= 8 else { return 0 }
        var bad = 0
        for w in sample {
            let cyr = w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            let lat = w.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
            if cyr && lat { bad += 1; continue }            // «смешанный алфавит» — почти всегда ошибка OCR
            if misspelled(w, language: cyr ? "ru" : "en") { bad += 1 }
        }
        return Double(bad) / Double(sample.count)
    }

    private static let checkerLock = NSLock()

    static func misspelled(_ word: String, language: String) -> Bool {
        checkerLock.lock(); defer { checkerLock.unlock() }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0.hasPrefix(language) }) else { return false }
        let r = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location != NSNotFound
    }
}
