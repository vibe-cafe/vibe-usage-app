import SwiftUI

// The two one-time banners of the interface-style rollout (#113). When they
// show is decided by `InterfaceStylePreference` (`showsClassicReminder`,
// `showsSwitchBackReminder`); these views only draw them.

// MARK: - Classic panel

/// An upgraded user on the classic panel: the first thing in its scrolling
/// content until 「先不用」 or 「切换新版」 is clicked, or the style is switched
/// in Settings. Closing the panel without an answer keeps it.
///
/// Same container as the classic custom-date bar (`FilterTagsView`): 0.08
/// fill, 1 pt 0.14 rule, 4 pt corners, 7 pt padding, the action a white 24 pt
/// capsule. 38 pt tall; the panel keeps its 620 pt and the content moves down.
struct ClassicStyleReminderBanner: View {
    static let message = "Vibe Usage 有新版皮肤了，要不要试试看？"
    static let tryModern = "切换新版"
    static let notNow = "先不用"

    let tryModern: () -> Void
    let notNow: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(Self.message)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.82))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: notNow) {
                Text(Self.notNow)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.6))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: tryModern) {
                Text(Self.tryModern)
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

// MARK: - New panel

/// After the classic banner's 「切换新版」: the first thing in the new panel's
/// scrolling middle (under the 概览 row, or under the header with one
/// subscription) until its × or its path is clicked (the path opens Settings
/// on 通用, where 「界面样式」 is), or the style is switched in Settings. It
/// counts in the content height, so the panel is 44 pt taller (36 + the 8 pt
/// card spacing) while it shows.
///
/// The classic banner's kind of thing in the new panel's language: text on
/// the 28 pt line, the × under the gear, a flat 6 % fill with the cards' 10 pt
/// corners (flat, so it does not read as a third card), 13 pt.
struct ModernSwitchBackBanner: View {
    static let lead = "想换回经典，可以在 "
    /// Read as 「设置 → 通用 → 界面样式」; the arrows are the header's own
    /// SF Symbol arrows (as in 「网页版 ↗」), not the text face's.
    static let path = ["设置", "通用", "界面样式"]
    static let tail = " 里切换"
    static let height: CGFloat = 36

    let openGeneralSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openGeneralSettings) {
                HStack(spacing: 0) {
                    Text(Self.lead)
                        .foregroundStyle(ModernTheme.secondaryText)
                    ForEach(Array(Self.path.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(ModernTheme.tertiaryText)
                                .padding(.horizontal, 5)
                        }
                        Text(step)
                            .foregroundStyle(ModernTheme.text)
                    }
                    Text(Self.tail)
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
        .padding(.horizontal, ModernTheme.textInset - ModernTheme.cardInset)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: ModernTheme.cardCornerRadius, style: .continuous)
                .fill(ModernTheme.text.opacity(0.06))
        )
    }
}
