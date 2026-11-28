import SwiftUI

/// The one-time reminder an upgraded user sees on the classic panel (#113):
/// one short line, 「试试新版」 and 「先不用」. Prototype: two candidate looks
/// for the maintainer to choose from, shown only when a renderer sets
/// `\.legacyStyleReminderLook`; the app never sets it yet.
enum LegacyStyleReminderLook: Equatable {
    /// A bar at the top of the scrolling content, in the custom-date bar's
    /// look (an inline tip: it pushes the content down, covers nothing).
    case banner
    /// A callout hanging from 「设置」 (a popover tip: it covers part of the
    /// content, the layout does not move).
    case popover
}

enum LegacyStyleReminderCopy {
    static let message = "Vibe Usage 有新版皮肤了，要不要试试看？"
    static let tryModern = "切换新版"
    static let notNow = "先不用"
}

private struct LegacyStyleReminderLookKey: EnvironmentKey {
    static let defaultValue: LegacyStyleReminderLook? = nil
}

extension EnvironmentValues {
    var legacyStyleReminderLook: LegacyStyleReminderLook? {
        get { self[LegacyStyleReminderLookKey.self] }
        set { self[LegacyStyleReminderLookKey.self] = newValue }
    }
}

/// Where 「设置」 sits, for the callout.
struct LegacyStyleReminderAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - A: bar

/// Same container as the classic custom-date bar (`FilterTagsView`): 0.08
/// fill, 1 pt 0.14 rule, 4 pt corners, 10 / 7 pt padding, a white 24 pt
/// capsule for the action. 38 pt tall.
struct LegacyStyleReminderBanner: View {
    let tryModern: () -> Void
    let notNow: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(LegacyStyleReminderCopy.message)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.82))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: notNow) {
                Text(LegacyStyleReminderCopy.notNow)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.6))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: tryModern) {
                Text(LegacyStyleReminderCopy.tryModern)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.14), lineWidth: 1))
    }
}

// MARK: - B: callout from 「设置」

/// A popover-style callout on one line, so it stays above the subscription
/// cards and covers only the tab strip's trailing end. Drawn by the panel
/// root (the quota tooltip's layer), so it is never clipped and the layout
/// under it does not move. The buttons are drawn to the metrics of macOS
/// push buttons (24 pt, 6 pt corners, 13 pt) rather than being native: a
/// native default button would take the user's accent color, and the
/// classic panel is black and white.
struct LegacyStyleReminderCallout: View {
    /// Where the arrow's tip points, from the callout's trailing edge.
    let arrowFromTrailing: CGFloat
    let tryModern: () -> Void
    let notNow: () -> Void

    static let arrowHeight: CGFloat = 7

    var body: some View {
        HStack(spacing: 8) {
            Text(LegacyStyleReminderCopy.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.trailing, 16)
            Button(LegacyStyleReminderCopy.notNow, action: notNow)
                .buttonStyle(ReminderPushButtonStyle(prominent: false))
            Button(LegacyStyleReminderCopy.tryModern, action: tryModern)
                .buttonStyle(ReminderPushButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 8 + Self.arrowHeight)
        .padding(.bottom, 8)
        .fixedSize()
        .background {
            let shape = CalloutShape(arrowFromTrailing: arrowFromTrailing, arrowHeight: Self.arrowHeight,
                                     cornerRadius: 8)
            shape.fill(Color(white: 0.13))
                .overlay(shape.stroke(Color(white: 0.26), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
        }
    }
}

/// A macOS push button's shape and size, in the classic panel's black and
/// white: the default action white with black text, the other a gray bezel.
private struct ReminderPushButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.black : Color(white: 0.92))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Color.white : Color(white: 0.25))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A rounded rectangle with an upward arrow on its top edge.
struct CalloutShape: Shape {
    let arrowFromTrailing: CGFloat
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight,
                          width: rect.width, height: rect.height - arrowHeight)
        let r = cornerRadius
        let half = arrowHeight + 1
        let tipX = min(max(body.maxX - arrowFromTrailing, body.minX + r + half), body.maxX - r - half)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: tipX - half, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: tipX, y: rect.minY + 0.5),
                          control: CGPoint(x: tipX - 1.5, y: rect.minY + 1))
        path.addQuadCurve(to: CGPoint(x: tipX + half, y: body.minY),
                          control: CGPoint(x: tipX + 1.5, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - New panel: how to switch back

/// Prototype (#113): after 「切换新版」 on the classic banner, the new panel
/// shows one bar at the top of its scrolling middle (under the 概览 row) until
/// its × is clicked, the path is clicked (it opens Settings on 通用, where
/// 「界面样式」 is) or the style is switched. The same kind of thing as the
/// classic banner, in the new panel's language: text on the 28 pt line, the ×
/// under the gear, a flat 6 % fill with the cards' 10 pt corners (flat, so it
/// does not read as a third card), 36 pt tall, 8 pt above 订阅配额.
private struct ModernSwitchBackNoticeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set only by renderers; the app never sets it yet.
    var modernSwitchBackNotice: Bool {
        get { self[ModernSwitchBackNoticeKey.self] }
        set { self[ModernSwitchBackNoticeKey.self] = newValue }
    }
}

enum ModernSwitchBackNoticeCopy {
    static let lead = "想换回经典，可以在 "
    /// Read as 「设置 → 通用 → 界面样式」; the arrows are the header's own
    /// SF Symbol arrows (as in 「网页版 ↗」), not the text face's.
    static let path = ["设置", "通用", "界面样式"]
    static let tail = " 里切换"
}

struct ModernSwitchBackBanner: View {
    let openGeneralSettings: () -> Void
    let dismiss: () -> Void

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openGeneralSettings) {
                HStack(spacing: 0) {
                    Text(ModernSwitchBackNoticeCopy.lead)
                        .foregroundStyle(ModernTheme.secondaryText)
                    ForEach(Array(ModernSwitchBackNoticeCopy.path.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(ModernTheme.tertiaryText)
                                .padding(.horizontal, 5)
                        }
                        Text(step)
                            .foregroundStyle(ModernTheme.text)
                    }
                    Text(ModernSwitchBackNoticeCopy.tail)
                        .foregroundStyle(ModernTheme.secondaryText)
                }
                .font(ModernTheme.text(13))
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .help("打开设置")
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .modernHitArea()
            }
            .buttonStyle(ModernIconButtonStyle(color: ModernTheme.tertiaryText))
            .help("关闭")
            .accessibilityLabel("关闭")
        }
        .padding(.leading, ModernTheme.textInset - ModernTheme.cardInset)
        .padding(.trailing, ModernTheme.textInset - ModernTheme.cardInset)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: ModernTheme.cardCornerRadius, style: .continuous)
                .fill(ModernTheme.text.opacity(0.06))
        )
    }
}
