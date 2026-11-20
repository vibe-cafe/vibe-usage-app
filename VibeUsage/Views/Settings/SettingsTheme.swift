import SwiftUI
import AppKit

/// Colors, type and metrics of the Settings window. Dark only: the window pins
/// `darkAqua` (maintainer decision 2026-11-20, 「只做深色」), so these are
/// fixed values rather than semantic system colors. They come from the
/// finalized design (`交接笔记/设置页设计-Fable/源文件/style.css`, dark block).
enum SettingsTheme {
    // MARK: Window

    static let windowSize = CGSize(width: 700, height: 460)
    static let sidebarWidth: CGFloat = 168
    static let contentTopInset: CGFloat = 20
    static let contentHorizontalInset: CGFloat = 22

    // MARK: Surfaces

    static let content = Color(settingsHex: 0x1E1E1E)
    static let sidebar = Color(settingsHex: 0x181818)
    static let card = Color(settingsHex: 0x292929)
    /// One step above the card: a dragged row, the selected segment track.
    static let raised = Color(settingsHex: 0x383838)
    /// The rounded block a configurable provider opens into.
    static let configBlock = Color(settingsHex: 0x323232)
    static let inset = Color(settingsHex: 0x1B1B1B)
    static let band = Color(settingsHex: 0x222222)
    static let line = Color.white.opacity(0.075)
    static let strongLine = Color.white.opacity(0.14)
    static let selection = Color.white.opacity(0.11)

    // MARK: Text

    static let text = Color(settingsHex: 0xE9E9E9)
    static let secondaryText = Color(settingsHex: 0x9C9C9C)
    static let tertiaryText = Color(settingsHex: 0x6A6A6A)

    // MARK: Accents
    // Green is the panel's "on"; red only for errors, expiry and reset; amber
    // only for "needs X" and the test-build tag.

    static let green = Color(settingsHex: 0x3CCB7F)
    static let amber = Color(settingsHex: 0xE5A43B)
    static let amberSoft = Color(settingsHex: 0xE5A43B).opacity(0.14)
    static let red = Color(settingsHex: 0xF0645D)

    // MARK: Controls

    static let switchTrack = Color.white.opacity(0.17)
    static let switchKnob = Color(settingsHex: 0xF4F4F4)
    static let buttonFill = Color.white.opacity(0.10)
    static let buttonLine = Color.white.opacity(0.10)
    static let segmentTrack = Color.white.opacity(0.07)
    static let segmentOn = Color(settingsHex: 0x505050)

    // MARK: Type (system font; 15 / 13 / 12 mono / 11)

    static let pageTitle = Font.system(size: 15, weight: .semibold)
    static let label = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 13)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let caption = Font.system(size: 11)
    static let tag = Font.system(size: 10, weight: .medium)

    static var contentNSColor: NSColor { NSColor(content) }
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

// MARK: - Cards and rows

/// A flat card: no border, no shadow, radius 10.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One card row: 44 pt (52 with a caption), 14 pt in from the left, 12 from
/// the right, 10 between items.
struct SettingsRow<Content: View>: View {
    var tall = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(minHeight: tall ? 52 : 44)
    }
}

/// The hairline between rows; starts at the rows' text inset, runs to the edge.
///
/// Takes no height: like the design's `::before` rule it is drawn over the
/// top pixel of the row below, so rows stay exactly 44 / 52 / 40 pt apart.
struct SettingsSeparator: View {
    var leading: CGFloat = 14

    var body: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .top) {
                SettingsTheme.line
                    .frame(height: 1)
                    .padding(.leading, leading)
            }
            .zIndex(1)
    }
}

/// A row's label with an optional caption line.
struct SettingsRowLabel: View {
    let title: String
    var caption: String?
    var captionColor: Color = SettingsTheme.secondaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(SettingsTheme.label)
                .foregroundStyle(SettingsTheme.text)
            if let caption {
                Text(caption)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Page title row: title, optional dim detail on the same baseline, optional
/// trailing control.
struct SettingsPageHeader<Detail: View, Trailing: View>: View {
    let title: String
    var advanced = false
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Like the design's baseline row: the title sits at the top of the
        // line, a trailing button is centered on the line.
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(SettingsTheme.pageTitle)
                        .foregroundStyle(SettingsTheme.text)
                    if advanced { SettingsAdvancedTag().offset(y: -1) }
                }
                detail
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }
}

extension SettingsPageHeader where Detail == EmptyView, Trailing == EmptyView {
    init(title: String, advanced: Bool = false) {
        self.init(title: title, advanced: advanced, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A group title above a card: one step smaller than the card's text,
/// semibold, secondary color (the About page Hogan liked, 2026-11-20).
struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsTheme.secondaryText)
            .padding(.horizontal, 2)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }
}

/// The grey 「高级」 chip after 「数据目录」.
struct SettingsAdvancedTag: View {
    var body: some View {
        Text("高级")
            .font(SettingsTheme.tag)
            .foregroundStyle(SettingsTheme.secondaryText)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(SettingsTheme.selection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The amber 「测试版」 chip.
struct SettingsTestBuildTag: View {
    var body: some View {
        Text("测试版")
            .font(SettingsTheme.tag)
            .foregroundStyle(SettingsTheme.amber)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(SettingsTheme.amberSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Status

enum SettingsStatusKind: Equatable {
    case ok, warning, error, none
}

/// 6 pt dot: green / amber / red, or a hollow ring for "nothing found".
struct SettingsStatusDot: View {
    let kind: SettingsStatusKind
    var dimmed = false

    var body: some View {
        Group {
            switch kind {
            case .ok: Circle().fill(SettingsTheme.green).opacity(dimmed ? 0.6 : 1)
            case .warning: Circle().fill(SettingsTheme.amber)
            case .error: Circle().fill(SettingsTheme.red)
            case .none: Circle().strokeBorder(SettingsTheme.tertiaryText, lineWidth: 1.2)
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

// MARK: - Switch

/// 30 × 18 switch with the panel's green. Drawn here rather than the system
/// switch so its size and color match the design in every window state.
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? SettingsTheme.green : SettingsTheme.switchTrack)
                Circle()
                    .fill(SettingsTheme.switchKnob)
                    .shadow(color: .black.opacity(0.3), radius: 0.75, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        // VoiceOver hears a standard switch with the Toggle's label.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

// MARK: - Buttons

/// 24 pt button: faint fill and hairline, radius 6, 13 pt text.
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

    var body: some View {
        configuration.label
            .font(SettingsTheme.body.weight(kind == .primary ? .medium : .regular))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, square ? 0 : 10)
            .frame(width: square ? 24 : nil, height: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(SettingsTheme.buttonLine, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .normal: SettingsTheme.text
        case .danger: SettingsTheme.red
        case .primary: SettingsTheme.content
        }
    }

    private var background: Color {
        kind == .primary ? SettingsTheme.text : SettingsTheme.buttonFill
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsDanger: SettingsButtonStyle { SettingsButtonStyle(kind: .danger) }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
    static var settingsSquare: SettingsButtonStyle { SettingsButtonStyle(square: true) }
}

/// A button label with a leading 13 pt symbol.
struct SettingsIconLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(title)
        }
    }
}

/// Borderless 22 pt icon button in the secondary color (＋ / － on paths).
struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsTheme.secondaryText)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Segmented control

/// Equal-height pill segments on a faint track; the selected segment is
/// raised. Used for the ZCode region.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(SettingsTheme.body)
                        .foregroundStyle(SettingsTheme.text)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(SettingsTheme.segmentOn)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(SettingsTheme.strongLine, lineWidth: 0.5)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SettingsTheme.segmentTrack, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isEnabled ? 1 : 0.6)
        .fixedSize()
    }
}

// MARK: - Text field

/// 26 pt inset field: dark fill, hairline, monospaced 12 pt text, a 13 pt
/// prompt while empty, and an optional clear button.
struct SettingsTextField: View {
    let prompt: String
    @Binding var text: String
    var secure = false
    var showsClearButton = false
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(SettingsTheme.body)
                        .foregroundStyle(SettingsTheme.tertiaryText)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                field
                    .textFieldStyle(.plain)
                    .font(SettingsTheme.mono)
                    .foregroundStyle(SettingsTheme.text)
            }
            if showsClearButton, !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsTheme.switchTrack)
                }
                .buttonStyle(.plain)
                .help("清空")
                .accessibilityLabel("清空")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, showsClearButton && !text.isEmpty ? 6 : 9)
        .frame(height: 26)
        .background(SettingsTheme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsTheme.strongLine, lineWidth: 1)
        )
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
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }
}
