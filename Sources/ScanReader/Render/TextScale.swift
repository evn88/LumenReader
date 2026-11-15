import AppKit
import CoreGraphics

/// Общий масштаб текста: диапазон, шаг кнопок A/A и автоматический подбор по физическому размеру.
enum TextScale {
    static let range: ClosedRange<Double> = 0.5...3.0
    static let step = 0.1

    /// Привести к сетке шага (0.1) и диапазону. Раньше «+» считался как
    /// `min(2.0, (s + 0.1) * 10).rounded() / 10` — кламп стоял не на том множителе и давал 0.2 (20%).
    static func clamp(_ s: Double) -> Double {
        let snapped = (s / step).rounded() * step
        return (min(range.upperBound, max(range.lowerBound, snapped)) * 100).rounded() / 100
    }

    static func increased(_ s: Double) -> Double { clamp(s + step) }
    static func decreased(_ s: Double) -> Double { clamp(s - step) }

    /// Подпись «140%» — ровно то, что применяется.
    static func percent(_ s: Double) -> String { "\(Int((clamp(s) * 100).rounded()))%" }

    // MARK: - автоматический масштаб

    /// Целевой кегль основного текста в pt «эталонного» экрана (~109 pt на дюйм, внешний 27″).
    /// 17 pt на нём — около 4 мм высоты строчных; на более плотных экранах нужно больше точек.
    static let targetPoints: CGFloat = 17
    static let referencePointsPerInch: CGFloat = 109

    /// Точек интерфейса на дюйм экрана (физически, по CGDisplayScreenSize).
    /// backingScaleFactor на физический размер не влияет (он меняет пиксели на точку, а не точки на дюйм).
    static func pointsPerInch(_ screen: NSScreen?) -> CGFloat {
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return referencePointsPerInch
        }
        let mm = CGDisplayScreenSize(id).width
        guard mm > 50 else { return referencePointsPerInch }       // проектор/неизвестный экран
        return screen.frame.width / (mm / 25.4)
    }

    /// Масштаб, при котором текст, сейчас видимый кеглем `bodyPoints`, станет комфортным на этом экране.
    /// Близкое к 1 (±12%) — оставляем 1: у сканов это точная раскладка строка в строку.
    static func auto(bodyPoints: CGFloat, pointsPerInch ppi: CGFloat) -> Double {
        guard bodyPoints > 1 else { return 1 }
        let want = targetPoints * ppi / referencePointsPerInch
        let s = Double(want / bodyPoints)
        if abs(s - 1) < 0.12 { return 1 }
        return clamp(s)
    }
}
