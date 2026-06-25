import SwiftUI
import VibeUsageCore

extension AppTheme {
    var palette: ThemePalette {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        case .grass:
            return .grass
        case .gold:
            return .gold
        }
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

struct ThemePalette {
    let windowBackground: Color
    let background: Color
    let card: Color
    let control: Color
    let controlHover: Color
    let border: Color
    let strongBorder: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let mutedText: Color
    let selectedBackground: Color
    let selectedText: Color
    let accent: Color
    let secondaryAccent: Color
    let link: Color
    let success: Color
    let warning: Color
    let danger: Color
    let tooltipBackground: Color
    let chartInput: Color
    let chartOutput: Color
    let chartNeutral: Color
    let chartOther: Color
    let progressTrack: Color

    static let dark = ThemePalette(
        windowBackground: Color(white: 0.04),
        background: Color(white: 0.04),
        card: Color(white: 0.09),
        control: Color(white: 0.12),
        controlHover: Color(white: 0.28),
        border: Color(white: 0.16),
        strongBorder: Color(white: 0.22),
        primaryText: .white,
        secondaryText: Color(white: 0.63),
        tertiaryText: Color(white: 0.50),
        mutedText: Color(white: 0.38),
        selectedBackground: .white,
        selectedText: .black,
        accent: Color(red: 0.20, green: 0.80, blue: 0.50),
        secondaryAccent: Color(red: 0.38, green: 0.60, blue: 1.00),
        link: Color(red: 0.40, green: 0.70, blue: 1.00),
        success: Color(red: 0.20, green: 0.80, blue: 0.50),
        warning: Color(red: 0.96, green: 0.62, blue: 0.04),
        danger: Color(red: 0.94, green: 0.27, blue: 0.27),
        tooltipBackground: .black,
        chartInput: Color(red: 0.20, green: 0.80, blue: 0.50),
        chartOutput: Color(red: 0.38, green: 0.60, blue: 1.00),
        chartNeutral: Color(white: 0.50),
        chartOther: Color(white: 0.32),
        progressTrack: Color(white: 0.14)
    )

    static let light = ThemePalette(
        windowBackground: Color(red: 0.96, green: 0.97, blue: 0.98),
        background: Color(red: 0.96, green: 0.97, blue: 0.98),
        card: .white,
        control: Color(red: 0.90, green: 0.92, blue: 0.94),
        controlHover: Color(red: 0.81, green: 0.85, blue: 0.89),
        border: Color(red: 0.80, green: 0.84, blue: 0.88),
        strongBorder: Color(red: 0.68, green: 0.73, blue: 0.78),
        primaryText: Color(red: 0.09, green: 0.12, blue: 0.16),
        secondaryText: Color(red: 0.32, green: 0.37, blue: 0.43),
        tertiaryText: Color(red: 0.45, green: 0.50, blue: 0.56),
        mutedText: Color(red: 0.55, green: 0.60, blue: 0.66),
        selectedBackground: Color(red: 0.12, green: 0.17, blue: 0.23),
        selectedText: .white,
        accent: Color(red: 0.05, green: 0.58, blue: 0.34),
        secondaryAccent: Color(red: 0.16, green: 0.43, blue: 0.85),
        link: Color(red: 0.13, green: 0.38, blue: 0.78),
        success: Color(red: 0.05, green: 0.58, blue: 0.34),
        warning: Color(red: 0.78, green: 0.46, blue: 0.02),
        danger: Color(red: 0.82, green: 0.16, blue: 0.16),
        tooltipBackground: Color(red: 0.10, green: 0.12, blue: 0.15),
        chartInput: Color(red: 0.05, green: 0.58, blue: 0.34),
        chartOutput: Color(red: 0.16, green: 0.43, blue: 0.85),
        chartNeutral: Color(red: 0.55, green: 0.60, blue: 0.66),
        chartOther: Color(red: 0.65, green: 0.69, blue: 0.74),
        progressTrack: Color(red: 0.86, green: 0.89, blue: 0.92)
    )

    static let grass = ThemePalette(
        windowBackground: Color(red: 0.93, green: 0.97, blue: 0.93),
        background: Color(red: 0.93, green: 0.97, blue: 0.93),
        card: Color(red: 0.98, green: 1.00, blue: 0.97),
        control: Color(red: 0.84, green: 0.91, blue: 0.82),
        controlHover: Color(red: 0.73, green: 0.84, blue: 0.70),
        border: Color(red: 0.72, green: 0.82, blue: 0.70),
        strongBorder: Color(red: 0.56, green: 0.70, blue: 0.54),
        primaryText: Color(red: 0.10, green: 0.20, blue: 0.13),
        secondaryText: Color(red: 0.27, green: 0.39, blue: 0.29),
        tertiaryText: Color(red: 0.42, green: 0.54, blue: 0.43),
        mutedText: Color(red: 0.54, green: 0.64, blue: 0.54),
        selectedBackground: Color(red: 0.16, green: 0.43, blue: 0.22),
        selectedText: .white,
        accent: Color(red: 0.12, green: 0.55, blue: 0.27),
        secondaryAccent: Color(red: 0.22, green: 0.50, blue: 0.64),
        link: Color(red: 0.12, green: 0.44, blue: 0.28),
        success: Color(red: 0.12, green: 0.55, blue: 0.27),
        warning: Color(red: 0.70, green: 0.50, blue: 0.06),
        danger: Color(red: 0.78, green: 0.18, blue: 0.15),
        tooltipBackground: Color(red: 0.12, green: 0.18, blue: 0.13),
        chartInput: Color(red: 0.12, green: 0.55, blue: 0.27),
        chartOutput: Color(red: 0.22, green: 0.50, blue: 0.64),
        chartNeutral: Color(red: 0.54, green: 0.64, blue: 0.54),
        chartOther: Color(red: 0.66, green: 0.74, blue: 0.63),
        progressTrack: Color(red: 0.83, green: 0.89, blue: 0.81)
    )

    static let gold = ThemePalette(
        windowBackground: Color(red: 0.98, green: 0.96, blue: 0.90),
        background: Color(red: 0.98, green: 0.96, blue: 0.90),
        card: Color(red: 1.00, green: 0.99, blue: 0.95),
        control: Color(red: 0.92, green: 0.86, blue: 0.72),
        controlHover: Color(red: 0.82, green: 0.74, blue: 0.57),
        border: Color(red: 0.83, green: 0.76, blue: 0.60),
        strongBorder: Color(red: 0.68, green: 0.57, blue: 0.36),
        primaryText: Color(red: 0.23, green: 0.17, blue: 0.08),
        secondaryText: Color(red: 0.43, green: 0.34, blue: 0.18),
        tertiaryText: Color(red: 0.56, green: 0.47, blue: 0.29),
        mutedText: Color(red: 0.66, green: 0.58, blue: 0.40),
        selectedBackground: Color(red: 0.55, green: 0.37, blue: 0.10),
        selectedText: .white,
        accent: Color(red: 0.70, green: 0.46, blue: 0.08),
        secondaryAccent: Color(red: 0.21, green: 0.46, blue: 0.72),
        link: Color(red: 0.55, green: 0.36, blue: 0.08),
        success: Color(red: 0.20, green: 0.55, blue: 0.25),
        warning: Color(red: 0.78, green: 0.47, blue: 0.04),
        danger: Color(red: 0.78, green: 0.18, blue: 0.14),
        tooltipBackground: Color(red: 0.18, green: 0.13, blue: 0.06),
        chartInput: Color(red: 0.70, green: 0.46, blue: 0.08),
        chartOutput: Color(red: 0.21, green: 0.46, blue: 0.72),
        chartNeutral: Color(red: 0.66, green: 0.58, blue: 0.40),
        chartOther: Color(red: 0.74, green: 0.66, blue: 0.48),
        progressTrack: Color(red: 0.90, green: 0.84, blue: 0.69)
    )
}
