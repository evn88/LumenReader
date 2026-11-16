import CoreGraphics
import Foundation

enum CodeLanguage: String, Codable, CaseIterable {
    case swift, kotlin, java, javascript, typescript, python, c, cpp, csharp, go, rust, php, ruby, sql, html, json, shell, plain

    var title: String {
        switch self {
        case .cpp: return "C++"
        case .csharp: return "C#"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .plain: return "Код"
        default: return rawValue.capitalized
        }
    }
}

/// Распознаём, что абзац — код, и определяем язык.
enum CodeDetector {
    /// Доля "кодовых" символов. У прозы ~0.02–0.03, у кода обычно > 0.07.
    static func symbolDensity(_ text: String) -> Double {
        let symbols = Set("{}[]()<>;=+-*/\\|&!#$:._\"'`@%^~")
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return 0 }
        return Double(chars.filter { symbols.contains($0) }.count) / Double(chars.count)
    }

    /// Моноширинность: ширина краски слова / число символов почти одинакова у всех слов.
    static func pitchVariation(_ lines: [TextLine]) -> Double {
        let ratios = lines.flatMap(\.words).filter { $0.text.count >= 3 }
            .map { Double($0.bounds.width) / (Double($0.text.count) - 0.3) }
        guard ratios.count >= 3 else { return 1 }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        let sd = sqrt(ratios.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ratios.count))
        return sd / mean
    }

    static func isCode(_ p: Paragraph) -> Bool {
        let text = p.lines.map(\.text).joined(separator: "\n")
        let density = symbolDensity(text)
        let mono = p.family == .mono || pitchVariation(p.lines) < 0.045
        let lang = detectLanguage(text)
        // короткая строка из нескольких слов («Таблица 2.2. Языки») — моноширинность по трём словам случайна
        let short = p.lines.count == 1 && p.lines[0].words.count < 6
        if short && lang.score < 3 && density <= 0.15 { return false }
        return (mono && (density > 0.04 || lang.score >= 3)) || density > 0.12 || (density > 0.07 && lang.score >= 3)
    }

    private static let rules: [CodeLanguage: [(String, Int)]] = [
        .swift: [("func ", 2), ("let ", 1), ("var ", 1), ("guard ", 3), ("import SwiftUI", 5), ("import Foundation", 4), ("->", 1), ("struct ", 2), ("@State", 4), ("extension ", 3), ("if let ", 3)],
        .kotlin: [("fun ", 3), ("val ", 3), ("when ", 2), ("data class", 5), ("println(", 2), ("override fun", 5), ("?.", 1)],
        .java: [("public class", 4), ("System.out", 5), ("void ", 2), ("private ", 1), ("import java", 5), ("new ", 1), ("String[]", 3), ("@Override", 3)],
        .javascript: [("function", 2), ("const ", 2), ("=>", 2), ("console.log", 5), ("require(", 4), ("document.", 4), ("export default", 3), ("===", 3)],
        .typescript: [(": string", 4), (": number", 4), ("interface ", 3), ("export ", 1), ("import {", 2), ("readonly ", 3), ("<T>", 2)],
        .python: [("def ", 3), ("self", 3), ("elif ", 5), ("print(", 2), ("None", 2), ("import ", 1), ("__init__", 5), ("lambda ", 2)],
        .c: [("#include", 4), ("printf", 3), ("int main", 3), ("NULL", 2), ("malloc(", 4), ("->", 1)],
        .cpp: [("std::", 5), ("#include <iostream>", 5), ("cout", 3), ("template<", 4), ("nullptr", 4), ("::", 1)],
        .csharp: [("using System", 5), ("namespace ", 3), ("Console.Write", 5), ("public void", 2), ("var ", 1), ("async Task", 4)],
        .go: [("package ", 4), ("func ", 2), (":=", 4), ("fmt.", 5), ("go func", 4), ("chan ", 3)],
        .rust: [("fn ", 3), ("let mut", 5), ("impl ", 4), ("println!", 5), ("pub fn", 4), ("&mut", 4), ("::", 1)],
        .php: [("<?php", 8), ("$this", 5), ("echo ", 2), ("->", 1), ("function ", 1)],
        .ruby: [("def ", 2), ("end", 1), ("puts ", 4), ("do |", 5), ("require '", 4), ("attr_accessor", 5)],
        .sql: [("SELECT ", 4), (" FROM ", 3), (" WHERE ", 3), ("INSERT INTO", 5), ("JOIN ", 3), ("CREATE TABLE", 5)],
        .html: [("<div", 4), ("</", 2), ("<html", 5), ("class=\"", 3), ("<span", 3), ("<!DOCTYPE", 6)],
        .json: [("\": ", 3), ("\": {", 3), ("\": [", 3)],
        .shell: [("#!/bin", 6), ("echo ", 2), ("$ ", 2), ("sudo ", 4), ("| grep", 4), ("export ", 2), ("apt-get", 4), ("brew ", 4)],
    ]

    static func detectLanguage(_ text: String) -> (language: CodeLanguage, score: Int) {
        var best: (CodeLanguage, Int) = (.plain, 0)
        for (lang, patterns) in rules {
            var score = 0
            for (p, w) in patterns {
                let n = text.components(separatedBy: p).count - 1
                score += min(n, 3) * w
            }
            if lang == .python, text.split(separator: "\n").contains(where: { $0.hasSuffix(":") }) { score += 2 }
            if lang == .json, text.trimmingCharacters(in: .whitespaces).hasPrefix("{") { score += 2 }
            if score > best.1 { best = (lang, score) }
        }
        return best.1 >= 3 ? best : (.plain, best.1)
    }
}

enum TokenKind { case keyword, string, comment, number, type, function, attribute, plain }

/// Простая подсветка синтаксиса регулярными выражениями (по строке).
enum SyntaxHighlighter {
    private static let keywords: [CodeLanguage: [String]] = [
        .swift: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "for", "in", "while", "switch", "case", "default", "self", "nil", "true", "false", "init", "private", "public", "static", "some", "async", "await", "throws", "try", "where"],
        .kotlin: ["fun", "val", "var", "if", "else", "when", "return", "class", "object", "data", "import", "package", "for", "in", "while", "null", "true", "false", "override", "private", "public", "this", "is", "as"],
        .java: ["public", "private", "protected", "class", "interface", "void", "int", "long", "boolean", "if", "else", "return", "new", "static", "final", "import", "package", "for", "while", "null", "true", "false", "this", "extends", "implements", "try", "catch", "throw"],
        .javascript: ["function", "const", "let", "var", "if", "else", "return", "class", "new", "import", "export", "from", "default", "for", "of", "in", "while", "null", "undefined", "true", "false", "this", "async", "await", "try", "catch"],
        .python: ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "for", "in", "while", "None", "True", "False", "self", "with", "lambda", "try", "except", "raise", "yield", "pass", "and", "or", "not", "is"],
        .c: ["int", "char", "void", "float", "double", "long", "unsigned", "struct", "if", "else", "return", "for", "while", "switch", "case", "break", "const", "static", "sizeof", "typedef", "NULL"],
        .csharp: ["using", "namespace", "class", "public", "private", "void", "int", "string", "var", "if", "else", "return", "new", "static", "async", "await", "foreach", "in", "null", "true", "false", "this"],
        .go: ["package", "import", "func", "var", "const", "type", "struct", "interface", "if", "else", "return", "for", "range", "go", "chan", "defer", "nil", "true", "false", "map"],
        .rust: ["fn", "let", "mut", "pub", "impl", "struct", "enum", "trait", "use", "mod", "if", "else", "match", "return", "for", "in", "while", "loop", "self", "Self", "true", "false", "where"],
        .php: ["function", "echo", "return", "if", "else", "class", "public", "private", "new", "foreach", "as", "null", "true", "false"],
        .ruby: ["def", "end", "if", "else", "elsif", "return", "class", "module", "do", "puts", "require", "nil", "true", "false", "self", "unless", "yield"],
        .sql: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "AND", "OR", "NOT", "NULL", "CREATE", "TABLE", "ORDER", "BY", "GROUP", "AS", "LIMIT"],
        .shell: ["if", "then", "else", "fi", "for", "do", "done", "echo", "export", "sudo", "cd", "case", "esac", "function"],
    ]

    static func tokens(_ line: String, _ lang: CodeLanguage) -> [(NSRange, TokenKind)] {
        var kw = keywords[lang] ?? []
        if lang == .typescript { kw = (keywords[.javascript] ?? []) + ["interface", "type", "string", "number", "boolean", "readonly", "implements"] }
        if lang == .cpp { kw = (keywords[.c] ?? []) + ["class", "template", "typename", "namespace", "std", "public", "private", "nullptr", "new", "delete", "auto", "bool", "true", "false"] }
        let lineComment: String
        switch lang {
        case .python, .ruby, .shell: lineComment = "#.*$"
        case .sql: lineComment = "--.*$"
        case .html: lineComment = "<!--.*?(-->|$)"
        default: lineComment = "//.*$|/\\*.*?(\\*/|$)"
        }
        var patterns: [(String, TokenKind, NSRegularExpression.Options)] = [
            (lineComment, .comment, []),
            ("\"(\\\\.|[^\"\\\\])*\"?|'(\\\\.|[^'\\\\])*'?|`[^`]*`?", .string, []),
            ("@\\w+", .attribute, []),
            ("\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b", .number, []),
        ]
        if !kw.isEmpty {
            patterns.append(("\\b(" + kw.map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")\\b",
                             .keyword, lang == .sql ? [.caseInsensitive] : []))
        }
        if lang == .html { patterns.append(("</?[A-Za-z][\\w-]*|/?>", .keyword, [])) }
        patterns.append(("\\b[A-Z][A-Za-z0-9_]*\\b", .type, []))
        patterns.append(("\\b[a-z_][A-Za-z0-9_]*(?=\\()", .function, []))

        let ns = line as NSString
        var taken = [Bool](repeating: false, count: ns.length)
        var out: [(NSRange, TokenKind)] = []
        for (p, kind, opts) in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: opts.union(.anchorsMatchLines)) else { continue }
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                let r = m.range
                if (r.location..<(r.location + r.length)).contains(where: { taken[$0] }) { continue }
                for i in r.location..<(r.location + r.length) { taken[i] = true }
                out.append((r, kind))
            }
        }
        return out
    }

    /// Цвета как в Xcode (светлая и тёмная тема).
    static func color(_ kind: TokenKind, dark: Bool, ink: CGColor) -> CGColor {
        func rgb(_ hex: UInt32) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch kind {
        case .keyword: return dark ? rgb(0xFF7AB2) : rgb(0x9B2393)
        case .string: return dark ? rgb(0xFF8170) : rgb(0xC41A16)
        case .comment: return dark ? rgb(0x7F8C98) : rgb(0x5D6C79)
        case .number: return dark ? rgb(0xD9C97C) : rgb(0x1C00CF)
        case .type: return dark ? rgb(0xDABAFF) : rgb(0x3900A0)
        case .function: return dark ? rgb(0x67B7A4) : rgb(0x326D74)
        case .attribute: return dark ? rgb(0xCC9768) : rgb(0x643820)
        case .plain: return ink
        }
    }
}

/// Синтаксическая проверка и исправление типичных ошибок OCR в коде.
enum CodeFixer {
    static let closer: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// Незакрытые скобки после данных строк (строки в кавычках и комментарии // пропускаются).
    static func openStack(_ lines: [String]) -> [Character] {
        var stack: [Character] = []
        for line in lines {
            var quote: Character? = nil
            var prev: Character = " "
            for ch in line {
                if let q = quote { if ch == q && prev != "\\" { quote = nil }; prev = ch; continue }
                if ch == "/" && prev == "/" { break }
                if ch == "\"" || ch == "'" || ch == "`" { quote = ch }
                else if closer[ch] != nil { stack.append(ch) }
                else if let last = stack.last, closer[last] == ch { stack.removeLast() }
                prev = ch
            }
        }
        return stack
    }

    /// Частые имена API: эталон написания (регистр, O/0) для идентификаторов из OCR.
    static let knownIdentifiers: Set<String> = [
        "JSONDecoder", "JSONEncoder", "JSONSerialization", "URLSession", "URLRequest", "URLComponents", "URL", "UUID",
        "HTTPURLResponse", "NSObject", "NSError", "NSString", "DispatchQueue", "UIView", "UIViewController",
        "NSView", "NSViewController", "UIImage", "NSImage", "CGRect", "CGPoint", "CGSize", "CGFloat", "IOException",
        "HTTPClient", "HTMLElement", "XMLHttpRequest", "JSON", "HTML", "HTTP", "HTTPS", "API", "XML", "SQL", "UI", "IO",
    ]

    /// Буквы, у которых строчная и заглавная формы почти одинаковы — их путает OCR.
    private static let confusable: Set<Character> = ["o", "O", "0", "s", "S", "c", "C", "v", "V", "w", "W", "x", "X", "z", "Z"]

    private static func key(_ s: String) -> String { s.uppercased().replacingOccurrences(of: "0", with: "O") }

    static func fix(_ lines: [String]) -> [String] {
        let wordRe = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
        var counts: [String: Int] = [:]
        for l in lines {
            for m in wordRe.matches(in: l, range: NSRange(l.startIndex..., in: l)) { counts[(l as NSString).substring(with: m.range), default: 0] += 1 }
        }
        // словарь: известные API + идентификаторы, встречающиеся в блоке не один раз
        var vocab: [String: String] = [:]
        for w in knownIdentifiers { vocab[key(w)] = w }
        for (w, n) in counts where n >= 2 { vocab[key(w)] = vocab[key(w)] ?? w }

        return lines.map { line in
            var s = line
            // $o / $O → $0 (аргументы замыканий Swift, $1 и т.д.)
            s = s.replacingOccurrences(of: #"\$[oO](?![A-Za-z0-9_])"#, with: #"\$0"#, options: .regularExpression)   // в шаблоне замены «$0» = всё совпадение
            // числа: O/o внутри цифр → 0
            let numRe = try! NSRegularExpression(pattern: #"(?<![A-Za-z_])(?=[0-9Oo]*[0-9])[0-9Oo]+(?![A-Za-z_])"#)
            for m in numRe.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                let r = Range(m.range, in: s)!
                s.replaceSubrange(r, with: s[r].replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0"))
            }
            // идентификаторы
            for m in wordRe.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                let r = Range(m.range, in: s)!
                let w = String(s[r])
                if let fixed = fixIdentifier(w, vocab: vocab), fixed != w { s.replaceSubrange(r, with: fixed) }
            }
            return s
        }
    }

    private static func fixIdentifier(_ w: String, vocab: [String: String]) -> String? {
        // по словарю: отличается только «путаемыми» буквами
        if let v = vocab[key(w)], v != w, v.count == w.count,
           zip(v, w).allSatisfy({ $0 == $1 || (confusable.contains($0) && confusable.contains($1)) }) {
            return v
        }
        // без словаря: строчная «путаемая» буква внутри аббревиатуры (JSoN, HTTpS): ≥2 заглавных перед ней и заглавная после
        var chars = Array(w)
        var changed = false
        for i in chars.indices where i >= 2 && i + 1 < chars.count && chars[i].isLowercase && confusable.contains(chars[i]) {
            if chars[i - 1].isUppercase && chars[i - 2].isUppercase && chars[i + 1].isUppercase {
                chars[i] = Character(chars[i].uppercased()); changed = true
            }
        }
        return changed ? String(chars) : nil
    }
}
