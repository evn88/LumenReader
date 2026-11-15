import XCTest
@testable import ScanReader

final class CodeTests: XCTestCase {
    func testDetectsSwift() {
        let code = """
        import Foundation
        struct User: Decodable { let id: Int }
        func load() async throws -> [User] { guard let x = y else { return [] } }
        """
        XCTAssertEqual(CodeDetector.detectLanguage(code).language, .swift)
    }

    func testDetectsPython() {
        let code = "def main(self):\n    if x is None:\n        print('hi')\n    elif y:\n        return None"
        XCTAssertEqual(CodeDetector.detectLanguage(code).language, .python)
    }

    func testProseIsNotCode() {
        XCTAssertEqual(CodeDetector.detectLanguage("Это обычный абзац текста про чтение книг.").language, .plain)
        XCTAssertLessThan(CodeDetector.symbolDensity("Обычный текст, без кода."), 0.05)
    }

    func testHighlighterTokens() {
        let line = "let count = 42 // comment"
        let kinds = SyntaxHighlighter.tokens(line, .swift).map(\.1)
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.number))
        XCTAssertTrue(kinds.contains(.comment))
        // комментарий не перекрашивается ключевыми словами внутри
        let ns = line as NSString
        let comment = SyntaxHighlighter.tokens(line, .swift).first { $0.1 == .comment }!
        XCTAssertEqual(ns.substring(with: comment.0), "// comment")
    }

    func testCodeFixerClosureArgAndAcronym() {
        let fixed = CodeFixer.fix(["return users.filter { $o.isActive }", "let d = try JSoNDecoder().decode(x)", "let n = 1O0"])
        XCTAssertEqual(fixed[0], "return users.filter { $0.isActive }")
        XCTAssertEqual(fixed[1], "let d = try JSONDecoder().decode(x)")
        XCTAssertEqual(fixed[2], "let n = 100")
    }

    func testCodeFixerKeepsValidIdentifiers() {
        let src = ["let id = user.id", "var IoT = device", "let url = URL(string: s)"]
        XCTAssertEqual(CodeFixer.fix(src), src)
    }

    func testBracketBalance() {
        XCTAssertEqual(CodeFixer.openStack(["struct A {", "  func f(x: [Int]) {", "    print(\"{\")"]), ["{", "{"])
        XCTAssertEqual(CodeFixer.openStack(["f(a, b)", "// {"]), [])
    }
}
