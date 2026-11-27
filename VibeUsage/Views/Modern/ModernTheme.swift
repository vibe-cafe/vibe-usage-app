import SwiftUI

/// Colors, type and metrics of the new ("modern") panel, from the finalized
/// design (workspace `VibeUsage界面改版/设计交接-回总控.md` §4, dark values;
/// `源文件/定稿.dc.html` for the exact numbers). Dark only for now — the
/// light variant (design §6) is a later ticket.
///
/// Four type sizes only (44 / 22 / 13 / 11). Color is reserved for problems:
/// amber for "using it fast", red for "nearly out"; everything else is the one
/// warm-white text color at a few opacities.
enum ModernTheme {
    // MARK: Panel

    static let panelWidth: CGFloat = 520
    static let panelCornerRadius: CGFloat = 16
    /// Cards sit 12 pt from the panel edge and pad 16 pt, so every text edge
    /// lines up at 28 pt.
    static let cardInset: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let textInset: CGFloat = 28
    static let cardSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    /// The card's left column (big number or ring).
    static let leadingColumnWidth: CGFloat = 160

    // MARK: Surfaces

    static let panel = Color(settingsHex: 0x131619)
    static let cardTop = Color(settingsHex: 0x1E2227)
    static let cardBottom = Color(settingsHex: 0x181B1F)
    /// The 概览 lamp's well.
    static let well = Color(settingsHex: 0x0D1013)
    static let lampOn = Color(settingsHex: 0xEEF0F2)
    static let lampOff = Color(settingsHex: 0x2B3036)

    // MARK: Text

    static let text = Color(settingsHex: 0xE7EBEE)
    /// Names that sit just below primary (the error label, row icons).
    static let strongText = text.opacity(0.86)
    static let secondaryText = text.opacity(0.62)
    /// Units and small icons.
    static let tertiaryText = text.opacity(0.5)
    /// Vertical separators in the header and footer.
    static let separator = text.opacity(0.14)
    /// Fill of a chip (「发现更新」, the selected period).
    static let chip = text.opacity(0.1)

    // MARK: Accents

    /// `oklch(0.80 0.11 75)`: a quota being used faster than its window.
    static let amber = Color(settingsHex: 0xE7B369)
    /// `oklch(0.70 0.14 28)`: nearly out, and errors.
    static let red = Color(settingsHex: 0xE8796C)

    // MARK: Type

    /// Schibsted Grotesk; Chinese falls back to PingFang SC.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .semibold, .bold, .heavy, .black: face = "SchibstedGrotesk-SemiBold"
        case .medium: face = "SchibstedGrotesk-Medium"
        default: face = "SchibstedGrotesk-Regular"
        }
        return .custom(face, fixedSize: size)
    }

    /// JetBrains Mono, for every number.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .ultraLight, .thin, .light: face = "JetBrainsMono-Light"
        case .medium, .semibold, .bold, .heavy, .black: face = "JetBrainsMono-Medium"
        default: face = "JetBrainsMono-Regular"
        }
        return .custom(face, fixedSize: size)
    }
}

/// The card surface: a top-to-bottom gradient, a 7% white highlight along the
/// top edge and a tight drop shadow (design §4).
struct ModernCardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ModernTheme.cardCornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [ModernTheme.cardTop, ModernTheme.cardBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                // `inset 0 1px 0 rgba(255,255,255,.07)`: a one-point line along
                // the top edge that thins out down the corners.
                shape
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    .mask(alignment: .top) {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: ModernTheme.cardCornerRadius)
                    }
            }
            .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
    }
}
