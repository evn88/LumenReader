import SwiftUI

/// Айдентика Lumen Reader: свет лампы для чтения — тёплый янтарный акцент на тёплом фоне.
/// Акцент задаётся только здесь (и в иконке: scripts/make-icon.swift).
enum Brand {
    /// Янтарь (#F2A33A). На тёмном — как есть, на светлом для текста — `amberText`.
    static let amber = Color(red: 0.949, green: 0.639, blue: 0.227)
    /// Янтарь для текста и иконок на светлом фоне (контраст ≥ 4.5:1 к фону библиотеки).
    static let amberDeep = Color(red: 0.60, green: 0.36, blue: 0.05)

    static func amberText(_ scheme: ColorScheme) -> Color { scheme == .dark ? amber : amberDeep }

    /// Фон библиотеки: тёплая бумага / тёплая темнота.
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.10, blue: 0.085) : Color(red: 0.975, green: 0.955, blue: 0.92)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.14, green: 0.125, blue: 0.105) : Color(red: 0.945, green: 0.915, blue: 0.865)
    }
}
