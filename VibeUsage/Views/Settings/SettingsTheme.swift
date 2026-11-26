import SwiftUI
import AppKit

/// Colors, type and metrics of the Settings window, one set per interface
/// style (`appState.interfaceStyle.current`). The window and every page are
/// the same in both; only these values and a few structural switches differ
/// (group titles inside or above the card, expanded content boxed or not,
/// sidebar width). Read it from the environment (`\.settingsTheme`), which
/// `SettingsWindowContent` sets, so switching the style redraws the open
/// window in place: same window, same per-window state.
///
/// Dark only in both: the window pins `darkAqua` (maintainer decision
/// 2026-11-20, 「只做深色」), so these are fixed values rather than semantic
/// system colors.
///
/// - Classic: the finalized 2026-11-20 design (`交接笔记/设置页设计-Fable/`),
///   unchanged.
/// - Modern: the panel's look (`VibeUsage界面改版/设计交接-回总控.md` §4 and
///   §10, drawings 138–143, values from `源文件/设置页.dc.html`).
struct SettingsTheme: Sendable {
    let style: InterfaceStyle
    var isModern: Bool { style == .modern }

    static func of(_ style: InterfaceStyle) -> SettingsTheme {
        style == .modern ? .modern : .classic
    }

    // MARK: Window

    static let windowSize = CGSize(width: 700, height: 460)
    /// Includes the 1 pt divider on its right.
    let sidebarWidth: CGFloat
    /// Where the window's traffic lights are centered (from the top left).
    let windowButtonCenter: CGPoint
    /// The page column: top, sides (the cards' outer edge) and bottom.
    let pageTopInset: CGFloat
    let pageHorizontalInset: CGFloat
    let pageBottomInset: CGFloat
    /// Space between two cards (or a card and the line under it).
    let cardGap: CGFloat

    // MARK: Surfaces

    let background: Color
    let sidebarBackground: Color
    let cardTop: Color
    let cardBottom: Color
    /// Inside a card: classic rows carry their own inset, modern cards pad.
    let cardPadding: EdgeInsets
    let rowLeading: CGFloat
    let rowTrailing: CGFloat
    let rowHeight: CGFloat
    let tallRowHeight: CGFloat
    /// A drag preview and the egress menu: one step above the card.
    let raised: Color
    /// Classic only: the rounded block an expanded row opens into.
    let configBlock: Color
    /// Text fields and path lines.
    let inset: Color
    /// Classic only: the 「未开启」 band.
    let band: Color
    let line: Color
    let strongLine: Color
    let selection: Color

    // MARK: Text

    let text: Color
    let secondaryText: Color
    let tertiaryText: Color

    // MARK: Accents
    // Classic: green is "on", red is error / expiry / reset, amber is "needs X".
    // Modern: no green; "on" and "fine" are lit (uncolored), amber means
    // "needs you", red only an error.

    /// A detected product's dot, check marks, the saved line's mark.
    let ok: Color
    /// The 「已保存，正在同步」 line under 额外 Codex Home.
    let success: Color
    let amber: Color
    let red: Color
    /// A dragged row's drop line.
    let dropLine: Color
    /// Accent for system-drawn bits (spinner, caret, selection).
    let tint: Color

    // MARK: Type

    let pageTitle: Font
    let pageTitleTracking: CGFloat
    let label: Font
    let body: Font
    /// Keys, paths, a code: a monospaced value inside a row.
    let mono: Font
    let caption: Font
    let tag: Font
    /// Group titles (更新, 诊断, 隐私保护 …).
    let sectionTitle: Font
    /// Short state words: the 状态 column, the 同步 line, the code line.
    let status: Font
    let fieldText: Font
    let fieldPrompt: Font
    /// Digits inside text (versions, counts, 「26 分钟前」); nil keeps the run's font.
    let numberFont: (@Sendable (Font.Weight) -> Font)?

    var contentNSColor: NSColor { NSColor(background) }

    // MARK: Values

    static let classic = SettingsTheme(
        style: .classic,
        sidebarWidth: 168,
        windowButtonCenter: CGPoint(x: 22, y: 24),
        pageTopInset: 20,
        pageHorizontalInset: 22,
        pageBottomInset: 22,
        cardGap: 16,
        background: Color(settingsHex: 0x1E1E1E),
        sidebarBackground: Color(settingsHex: 0x181818),
        cardTop: Color(settingsHex: 0x292929),
        cardBottom: Color(settingsHex: 0x292929),
        cardPadding: EdgeInsets(),
        rowLeading: 14,
        rowTrailing: 12,
        rowHeight: 44,
        tallRowHeight: 52,
        raised: Color(settingsHex: 0x383838),
        configBlock: Color(settingsHex: 0x323232),
        inset: Color(settingsHex: 0x1B1B1B),
        band: Color(settingsHex: 0x222222),
        line: Color.white.opacity(0.075),
        strongLine: Color.white.opacity(0.14),
        selection: Color.white.opacity(0.11),
        text: Color(settingsHex: 0xE9E9E9),
        secondaryText: Color(settingsHex: 0x9C9C9C),
        tertiaryText: Color(settingsHex: 0x6A6A6A),
        ok: Color(settingsHex: 0x3CCB7F),
        success: Color(settingsHex: 0x3CCB7F),
        amber: Color(settingsHex: 0xE5A43B),
        red: Color(settingsHex: 0xF0645D),
        dropLine: Color(settingsHex: 0x3CCB7F),
        tint: Color(settingsHex: 0x3CCB7F),
        pageTitle: .system(size: 15, weight: .semibold),
        pageTitleTracking: 0,
        label: .system(size: 13, weight: .medium),
        body: .system(size: 13),
        mono: .system(size: 12, design: .monospaced),
        caption: .system(size: 11),
        tag: .system(size: 10, weight: .medium),
        sectionTitle: .system(size: 12, weight: .semibold),
        status: .system(size: 13),
        fieldText: .system(size: 12, design: .monospaced),
        fieldPrompt: .system(size: 13),
        numberFont: nil
    )

    private static let ink = Color(settingsHex: 0xE7EBEE)

    static let modern = SettingsTheme(
        style: .modern,
        sidebarWidth: 180,
        windowButtonCenter: CGPoint(x: 26, y: 22),
        pageTopInset: 0,
        pageHorizontalInset: 12,
        pageBottomInset: 14,
        cardGap: 8,
        background: Color(settingsHex: 0x131619),
        sidebarBackground: Color(settingsHex: 0x131619),
        cardTop: Color(settingsHex: 0x1E2227),
        cardBottom: Color(settingsHex: 0x181B1F),
        cardPadding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16),
        rowLeading: 0,
        rowTrailing: 0,
        rowHeight: 36,
        tallRowHeight: 48,
        raised: Color(settingsHex: 0x2A2E34),
        configBlock: .clear,
        inset: ink.opacity(0.08),
        band: .clear,
        line: ink.opacity(0.08),
        strongLine: ink.opacity(0.45),
        selection: ink.opacity(0.10),
        text: ink,
        secondaryText: ink.opacity(0.62),
        tertiaryText: ink.opacity(0.50),
        ok: ink.opacity(0.86),
        success: ink.opacity(0.62),
        amber: Color(settingsHex: 0xE7B369),
        red: Color(settingsHex: 0xE8796C),
        dropLine: Color(settingsHex: 0xEEF0F2),
        tint: ink,
        pageTitle: SettingsFont.text(13, .semibold),
        pageTitleTracking: -0.13,
        label: SettingsFont.text(13, .medium),
        body: SettingsFont.text(13),
        mono: SettingsFont.number(11),
        caption: SettingsFont.text(11),
        tag: SettingsFont.text(11, .medium),
        sectionTitle: SettingsFont.text(13, .semibold),
        status: SettingsFont.text(11),
        fieldText: SettingsFont.number(11),
        fieldPrompt: SettingsFont.text(11),
        numberFont: { SettingsFont.number(11, $0) }
    )
}

/// The modern style's two typefaces, the new panel's own (`ModernTheme`,
/// bundled in `Resources/Fonts` and registered by `AppFonts`): Schibsted
/// Grotesk for text, JetBrains Mono for digits, versions, paths and keys.
/// Chinese falls back to PingFang SC. Classic keeps the system font.
enum SettingsFont {
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        ModernTheme.text(size, weight)
    }

    static func number(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        ModernTheme.mono(size, weight)
    }
}

extension EnvironmentValues {
    @Entry var settingsTheme: SettingsTheme = .classic
}

extension Color {
    /// `0xRRGGBB`, sRGB.
    init(settingsHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Text with digits

/// A line whose digit runs use the theme's number face (modern: 「26」 in
/// 「正常 · 26 分钟前」, versions, counts); classic draws it as plain text.
struct SettingsNumberText: View {
    let string: String
    var font: Font
    var numberSize: CGFloat = 11
    var weight: Font.Weight = .regular
    @Environment(\.settingsTheme) private var theme

    init(_ string: String, font: Font, numberSize: CGFloat = 11, weight: Font.Weight = .regular) {
        self.string = string
        self.font = font
        self.numberSize = numberSize
        self.weight = weight
    }

    var body: some View {
        Self.text(string, font: font, numberFont: theme.isModern ? SettingsFont.number(numberSize, weight) : nil)
    }

    /// Number runs in `numberFont`, the rest in `font` (see `runs`).
    static func text(_ string: String, font: Font, numberFont: Font?) -> Text {
        guard let numberFont else { return Text(string).font(font) }
        return runs(string).reduce(Text("")) { result, run in
            result + Text(run.text).font(run.isNumber ? numberFont : font)
        }
    }

    /// `string` cut into number and text runs. A number is digits and dots,
    /// with a following 「 (47)」 build number, so 「0.8.1 (47)」 is one run.
    static func runs(_ string: String) -> [(text: String, isNumber: Bool)] {
        let source = string as NSString
        var result: [(text: String, isNumber: Bool)] = []
        var location = 0
        for match in numberRuns.matches(in: string, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > location {
                result.append((source.substring(with: NSRange(location: location, length: match.range.location - location)), false))
            }
            result.append((source.substring(with: match.range), true))
            location = match.range.location + match.range.length
        }
        if location < source.length {
            result.append((source.substring(from: location), false))
        }
        return result
    }

    private static let numberRuns = try! NSRegularExpression(pattern: "[0-9][0-9.]*(?: \\([0-9]+\\))?")
}

// MARK: - Cards and rows

/// A card. Classic: flat, no border, radius 10; rows carry their own inset.
/// Modern: the panel's card — a top-to-bottom gradient with a hairline top
/// highlight and a small shadow, 16 pt side padding.
struct SettingsCard<Content: View>: View {
    var padding: EdgeInsets?
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding ?? theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SettingsCardBackground() }
    }
}

struct SettingsCardBackground: View {
    var cornerRadius: CGFloat = 10
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if theme.isModern {
            shape
                .fill(LinearGradient(colors: [theme.cardTop, theme.cardBottom], startPoint: .top, endPoint: .bottom))
                .overlay {
                    // `inset 0 1px 0 rgba(255,255,255,.07)`: a hairline along
                    // the top edge that follows the corners and fades out.
                    shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        .mask(LinearGradient(
                            stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.06)],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
        } else {
            shape.fill(theme.cardTop)
        }
    }
}

/// One card row. Classic: 44 pt (52 with a caption), 14 pt in from the left,
/// 12 from the right. Modern: 36 pt (48 with a caption) under a 1 pt rule
/// slot — the panel's 37 pt row — with the card's padding for its sides.
struct SettingsRow<Content: View>: View {
    var tall = false
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: spacing) { content }
            .padding(.leading, theme.rowLeading)
            .padding(.trailing, theme.rowTrailing)
            .frame(minHeight: tall ? theme.tallRowHeight : theme.rowHeight)
            .padding(.top, theme.isModern ? 1 : 0)
    }
}

/// The hairline between rows. Classic: from the rows' text inset to the
/// card's edge. Modern: across the card's padded width.
///
/// Takes no height: like the design's `::before` / `border-top` rule it is
/// drawn over the top pixel of the row below, so rows keep their exact pitch.
struct SettingsSeparator: View {
    var leading: CGFloat?
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .top) {
                theme.line
                    .frame(height: 1)
                    .padding(.leading, leading ?? (theme.isModern ? 0 : 14))
            }
            .zIndex(1)
    }
}

/// A row's label with an optional caption line.
struct SettingsRowLabel: View {
    let title: String
    var caption: String?
    var captionColor: Color?
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.isModern ? 2 : 1) {
            SettingsNumberText.text(
                title, font: theme.label,
                numberFont: theme.isModern ? SettingsFont.number(13) : nil
            )
            .foregroundStyle(theme.text)
            if let caption {
                Text(caption)
                    .font(theme.caption)
                    .foregroundStyle(captionColor ?? theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Page title row: title, optional dim detail on the same baseline, optional
/// trailing control. Modern: the panel's 44 pt title bar, text at 28.
struct SettingsPageHeader<Detail: View, Trailing: View>: View {
    let title: String
    var advanced = false
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        // Like the design's baseline row: the title sits at the top of the
        // line, a trailing button is centered on the line.
        HStack(alignment: theme.isModern ? .center : .top, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: theme.isModern ? 8 : 6) {
                    Text(title)
                        .font(theme.pageTitle)
                        .tracking(theme.pageTitleTracking)
                        .foregroundStyle(theme.text)
                    if advanced { SettingsAdvancedTag().offset(y: theme.isModern ? 0 : -1) }
                }
                detail
            }
            .padding(.top, theme.isModern ? 0 : 1)
            Spacer(minLength: 0)
            trailing
        }
        // Modern: a fixed 20 pt line; a 24 pt button overhangs it evenly.
        .frame(height: theme.isModern ? 20 : nil)
        .padding(.horizontal, theme.isModern ? 16 : 2)
        .padding(.top, theme.isModern ? 12 : 0)
        .padding(.bottom, theme.isModern ? 12 : 10)
    }
}

extension SettingsPageHeader where Detail == EmptyView, Trailing == EmptyView {
    init(title: String, advanced: Bool = false) {
        self.init(title: title, advanced: advanced, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A titled group of rows. Classic: the title above the card. Modern: the
/// title inside the card, the way the panel titles 订阅配额 and 近期消耗.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !theme.isModern { SettingsSectionTitle(title: title) }
            SettingsCard {
                if theme.isModern { SettingsSectionTitle(title: title) }
                content
            }
        }
        .padding(.top, theme.isModern ? theme.cardGap : 0)
    }
}

/// A group title. Classic: above a card, one step smaller than the card's
/// text, semibold, secondary color (the About page Hogan liked, 2026-11-20).
/// Modern: the card's first line, 13 pt semibold, secondary color.
struct SettingsSectionTitle: View {
    let title: String
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Text(title)
            .font(theme.sectionTitle)
            .foregroundStyle(theme.secondaryText)
            .frame(height: theme.isModern ? 20 : nil)
            .padding(.horizontal, theme.isModern ? 0 : 2)
            .padding(.top, theme.isModern ? 8 : 18)
            .padding(.bottom, theme.isModern ? 2 : 7)
    }
}

/// A small chip after a title: 「高级」 after 数据目录, 「测试版」 after 导出诊断日志.
/// Classic: grey 「高级」, amber 「测试版」. Modern: both uncolored (amber means
/// "needs you" there), the panel's 18 pt pill.
struct SettingsTag: View {
    enum Kind { case advanced, testBuild }
    let kind: Kind
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let title = kind == .advanced ? "高级" : "测试版"
        if theme.isModern {
            Text(title)
                .font(theme.tag)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background { Capsule().fill(theme.inset) }
        } else if kind == .advanced {
            Text(title)
                .font(theme.tag)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(theme.selection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Text(title)
                .font(theme.tag)
                .foregroundStyle(theme.amber)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(theme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

struct SettingsAdvancedTag: View {
    var body: some View { SettingsTag(kind: .advanced) }
}

struct SettingsTestBuildTag: View {
    var body: some View { SettingsTag(kind: .testBuild) }
}

// MARK: - Status

enum SettingsStatusKind: Equatable {
    case ok, warning, error, none
}

/// 6 pt dot: ok / amber / red, or a hollow ring for "nothing found". Classic
/// ok is green; modern ok is a lit, uncolored dot.
struct SettingsStatusDot: View {
    let kind: SettingsStatusKind
    var dimmed = false
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Group {
            switch kind {
            case .ok: Circle().fill(theme.ok).opacity(dimmed ? (theme.isModern ? 0.45 : 0.6) : 1)
            case .warning: Circle().fill(theme.amber).opacity(dimmed && theme.isModern ? 0.45 : 1)
            case .error: Circle().fill(theme.red)
            case .none:
                Circle().strokeBorder(
                    theme.isModern ? theme.text.opacity(0.38) : theme.tertiaryText,
                    lineWidth: theme.isModern ? 1.5 : 1.2
                )
            }
        }
        .frame(width: 6, height: 6)
    }
}

struct SettingsSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 12, height: 12)
    }
}

/// A check mark before a done state (「Key 已保存」, 「已复制」, the signed-in
/// email, 「已保存，正在同步」).
struct SettingsCheckMark: View {
    var size: CGFloat = 11
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(theme.ok)
    }
}

// MARK: - Switch

/// 30 × 18 switch, drawn here rather than the system switch so its size and
/// color match the design in every window state. Classic: the panel's green.
/// Modern: no green — on is a lit groove and a glowing knob, off a dark
/// groove and a dim knob.
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            SettingsSwitchTrack(isOn: configuration.isOn)
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : (theme.isModern ? 0.4 : 0.45))
        // VoiceOver hears a standard switch with the Toggle's label.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The switch's drawing, also used by a dragged row's preview.
struct SettingsSwitchTrack: View {
    let isOn: Bool
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            if theme.isModern {
                Capsule()
                    .fill(isOn
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(settingsHex: 0x59616A), Color(settingsHex: 0x767F88)],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(settingsHex: 0x0D1013)))
                    .overlay {
                        // `inset 0 1px 2px` and the 1 pt lower lip.
                        Capsule()
                            .strokeBorder(Color.black.opacity(isOn ? 0.5 : 0.8), lineWidth: 1)
                            .blur(radius: 1)
                            .offset(y: 1)
                            .clipShape(Capsule())
                    }
                    .background {
                        Capsule().fill(Color.white.opacity(0.06)).offset(y: 1)
                    }
                Circle()
                    .fill(isOn
                        ? AnyShapeStyle(Color(settingsHex: 0xEEF0F2))
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color(settingsHex: 0x3B4148), Color(settingsHex: 0x2A2F35)],
                            startPoint: .top, endPoint: .bottom)))
                    .overlay {
                        if !isOn {
                            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                        }
                    }
                    .shadow(color: .black.opacity(isOn ? 0.45 : 0.6), radius: 1, y: 1)
                    .shadow(color: isOn ? theme.text.opacity(0.45) : .clear, radius: 2.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            } else {
                Capsule()
                    .fill(isOn ? theme.ok : Color.white.opacity(0.17))
                Circle()
                    .fill(Color(settingsHex: 0xF4F4F4))
                    .shadow(color: .black.opacity(0.3), radius: 0.75, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
        }
        .frame(width: 30, height: 18)
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

// MARK: - Buttons

/// 24 pt button. Classic: faint fill and hairline, radius 6, 13 pt text; the
/// destructive ones in red. Modern: the panel's pill — 10 % ink, fully round,
/// 13 pt medium; no red (the system confirmation that follows says it); the
/// one button that matters most (「链接」 while unlinked) white on dark.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case normal, danger, primary }
    var kind: Kind = .normal
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, kind: kind, square: square)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SettingsButtonStyle.Kind
    let square: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.isModern ? 12 : 6, style: .continuous)
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, square ? 0 : (theme.isModern ? 11 : 10))
            .frame(width: square ? 24 : nil, height: 24)
            .background(background, in: shape)
            .overlay {
                if kind != .primary, !theme.isModern {
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : (theme.isModern ? 0.4 : 0.45))
            .contentShape(shape)
    }

    private var font: Font {
        if theme.isModern { return SettingsFont.text(13, kind == .primary ? .semibold : .medium) }
        return theme.body.weight(kind == .primary ? .medium : .regular)
    }

    private var foreground: Color {
        switch kind {
        case .normal: theme.text
        case .danger: theme.isModern ? theme.text : theme.red
        case .primary: theme.isModern ? Color(settingsHex: 0x16191C) : theme.background
        }
    }

    private var background: Color {
        if kind == .primary { return theme.text }
        return theme.isModern ? theme.text.opacity(0.10) : Color.white.opacity(0.10)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsDanger: SettingsButtonStyle { SettingsButtonStyle(kind: .danger) }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
    static var settingsSquare: SettingsButtonStyle { SettingsButtonStyle(square: true) }
}

/// A button label with a leading symbol.
struct SettingsIconLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: theme.isModern ? 10 : 11, weight: theme.isModern ? .semibold : .medium))
            Text(title)
        }
    }
}

/// ＋ / － on the 数据目录 page. Classic: a borderless 22 pt icon in the
/// secondary color. Modern: a 22 pt round button like the panel's.
struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsIconButtonBody(configuration: configuration)
    }
}

private struct SettingsIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        configuration.label
            .font(.system(size: theme.isModern ? 10 : 12, weight: theme.isModern ? .semibold : .medium))
            .foregroundStyle(theme.isModern ? theme.text : theme.secondaryText)
            .frame(width: 22, height: 22)
            .background { Circle().fill(theme.isModern ? theme.text.opacity(0.10) : .clear) }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : (theme.isModern && !isEnabled ? 0.4 : 1))
    }
}

// MARK: - Segmented control

/// A two-way choice (the ZCode region, the interface style). Classic: equal
/// pill segments on a faint track, the selected one raised. Modern: the
/// panel's period chips — 20 pt pills, the selected one lit.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: theme.isModern ? 2 : 0) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(theme.isModern ? SettingsFont.text(11, isOn ? .medium : .regular) : theme.body)
                        .foregroundStyle(theme.isModern && !isOn ? theme.secondaryText : theme.text)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, theme.isModern ? 8 : 11)
                        .frame(height: theme.isModern ? 20 : 22)
                        .background {
                            if isOn {
                                if theme.isModern {
                                    Capsule().fill(theme.text.opacity(0.10))
                                } else {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color(settingsHex: 0x505050))
                                        .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .strokeBorder(theme.strongLine, lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(theme.isModern ? 0 : 2)
        .background {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07))
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
        .fixedSize()
    }
}

// MARK: - Text field

/// An inset text field with a prompt while empty and an optional clear
/// button. Classic: 26 pt, dark fill, hairline, 12 pt mono text, 13 pt
/// prompt. Modern: the panel's date field — 24 pt, 8 % ink, radius 6, 11 pt,
/// a lit ring while editing.
struct SettingsTextField: View {
    let prompt: String
    @Binding var text: String
    var secure = false
    var showsClearButton = false
    var focus: FocusState<Bool>.Binding?
    @FocusState private var ownFocus: Bool
    @Environment(\.settingsTheme) private var theme

    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(theme.fieldPrompt)
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                field
                    .textFieldStyle(.plain)
                    .font(theme.fieldText)
                    .foregroundStyle(theme.text)
            }
            if showsClearButton, !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    if theme.isModern {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(theme.background)
                            .frame(width: 14, height: 14)
                            .background { Circle().fill(theme.text.opacity(0.16)) }
                            .contentShape(Circle())
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.17))
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .help("清空")
                .accessibilityLabel("清空")
            }
        }
        .padding(.leading, theme.isModern ? 8 : 9)
        .padding(.trailing, showsClearButton && !text.isEmpty ? (theme.isModern ? 5 : 6) : (theme.isModern ? 8 : 9))
        .frame(height: theme.isModern ? 24 : 26)
        .background(theme.inset, in: shape)
        .overlay {
            if theme.isModern {
                if isFocused { shape.inset(by: -1.5).strokeBorder(theme.strongLine, lineWidth: 1.5) }
            } else {
                shape.strokeBorder(theme.strongLine, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            if secure {
                SecureField("", text: $text).focused(focus)
            } else {
                TextField("", text: $text).focused(focus)
            }
        } else if secure {
            SecureField("", text: $text).focused($ownFocus)
        } else {
            TextField("", text: $text).focused($ownFocus)
        }
    }
}
