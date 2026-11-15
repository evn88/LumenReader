import XCTest
@testable import ScanReader

final class TextScaleTests: XCTestCase {
    /// Баг: «большая A» ставила 20% (кламп на множителе ×10).
    func testIncreaseFromAnyValue() {
        XCTAssertEqual(TextScale.increased(1.0), 1.1, accuracy: 1e-9)
        XCTAssertEqual(TextScale.increased(1.4), 1.5, accuracy: 1e-9)
        XCTAssertEqual(TextScale.increased(2.0), 2.1, accuracy: 1e-9)
        XCTAssertEqual(TextScale.increased(3.0), 3.0, accuracy: 1e-9)
        XCTAssertEqual(TextScale.decreased(0.5), 0.5, accuracy: 1e-9)
    }

    func testStepIsSymmetric() {
        var s = 1.0
        for _ in 0..<7 { s = TextScale.increased(s) }
        for _ in 0..<7 { s = TextScale.decreased(s) }
        XCTAssertEqual(s, 1.0, accuracy: 1e-9)
    }

    func testClampAndLabel() {
        XCTAssertEqual(TextScale.clamp(0.2), 0.5)
        XCTAssertEqual(TextScale.clamp(9), 3.0)
        XCTAssertEqual(TextScale.clamp(1.43), 1.4, accuracy: 1e-9)
        XCTAssertEqual(TextScale.percent(1.4), "140%")
        XCTAssertEqual(TextScale.percent(TextScale.increased(1.4)), "150%")
    }

    func testAutoScaleByDensity() {
        // эталонный экран, текст уже 17 pt — без изменений (точная раскладка сканов)
        XCTAssertEqual(TextScale.auto(bodyPoints: 17, pointsPerInch: 109), 1)
        // Air 13″ (~127 pt/дюйм): тот же текст физически мельче — увеличиваем
        XCTAssertEqual(TextScale.auto(bodyPoints: 12, pointsPerInch: 127.5), 1.7, accuracy: 0.05)
        // мелкий скан в маленьком окне
        XCTAssertGreaterThan(TextScale.auto(bodyPoints: 8, pointsPerInch: 109), 2)
        // огромный текст — уменьшаем, но не ниже 50%
        XCTAssertEqual(TextScale.auto(bodyPoints: 60, pointsPerInch: 109), 0.5)
    }
}
