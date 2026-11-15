import XCTest
import ImageIO
@testable import ScanReader

final class LayoutTests: XCTestCase {
    static let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("demo")

    static func image(_ name: String) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(demo.appendingPathComponent(name) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// Раскладка demo/synthetic-page.png: колонтитул, выключенные строки, иллюстрация, подпись.
    func testSamplePageLayout() throws {
        let page = try LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"], enhanceFigures: false)
            .analyze(Self.image("synthetic-page.png"))
        let l = page.layout
        XCTAssertEqual(l.figures.count, 1)
        XCTAssertEqual(l.rules.count, 1)
        let lines = l.allLines
        XCTAssertGreaterThanOrEqual(lines.filter { $0.alignment == .justify }.count, 3)
        XCTAssertTrue(lines.contains { $0.text.contains("React") })
        let header = try XCTUnwrap(l.paragraphs.first { $0.lines.contains { $0.text.contains("Глава") } })
        XCTAssertNotEqual(header.family, .mono, "колонтитул курсивом — не моноширинный")
        let caption = try XCTUnwrap(lines.first { $0.text.hasPrefix("Рис.") })
        XCTAssertEqual(caption.alignment, .center)
        XCTAssertTrue(caption.words.first?.bold ?? false)
        XCTAssertTrue(l.codeBlocks.isEmpty, "подпись не код")
        XCTAssertFalse(PageQuality.isUnreliable(l))
    }

    /// demo/code-page.png: блок Swift, восстановленные `}` и исправления OCR.
    func testCodePage() throws {
        let page = try LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"], enhanceFigures: false)
            .analyze(Self.image("code-page.png"))
        let block = try XCTUnwrap(page.layout.codeBlocks.first)
        XCTAssertEqual(block.language, .swift)
        // точный текст зависит от моделей Vision: на виртуальных машинах CI (без Neural Engine) OCR другой
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil else { return }
        let text = block.text
        XCTAssertTrue(text.contains("JSONDecoder"))
        XCTAssertTrue(text.contains("$0.isActive"))
        XCTAssertEqual(CodeFixer.openStack(block.lines.map(\.text)), [], "скобки сбалансированы")
        XCTAssertEqual(block.lines.filter { $0.text == "}" }.count, 2)
    }

    func testReflowKeepsAllText() throws {
        let page = try LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"], enhanceFigures: false)
            .analyze(Self.image("synthetic-page.png"))
        for scale in [0.8, 1.4, 2.0] {
            let screens = Reflow.paginate(page.layout, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                          settings: ReflowSettings(scale: scale))
            XCTAssertGreaterThanOrEqual(screens.count, 1)
            let figures = screens.flatMap(\.items).filter { if case .figure = $0 { return true }; return false }
            XCTAssertEqual(figures.count, 1, "иллюстрация ровно одна при \(scale)")
        }
    }

    func testCancelledAnalysisStops() throws {
        let token = CancelToken()
        token.cancel()
        var analyzer = LayoutAnalyzer(palette: .original, languages: ["ru-RU"], enhanceFigures: false)
        analyzer.token = token
        XCTAssertThrowsError(try analyzer.analyze(Self.image("synthetic-page.png"))) { XCTAssertTrue($0 is CancellationError) }
    }
}

final class SyntheticPageReflowTests: XCTestCase {
    /// Настоящий скан: «Единствен-» в конце короткой строки + «ное» на следующей → одно слово при перекомпоновке.
    func testHyphenOnScannedPage() throws {
        let page = try LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"], enhanceFigures: false)
            .analyze(LayoutTests.image("synthetic-page.png"))
        let screens = Reflow.paginate(page.layout, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                      settings: ReflowSettings(scale: 1.4))
        let text = screens.flatMap(\.lineTexts).joined(separator: " ")
        XCTAssertTrue(text.contains("Единственное"), text)
        XCTAssertFalse(text.contains("Единствен-"))
    }
}
