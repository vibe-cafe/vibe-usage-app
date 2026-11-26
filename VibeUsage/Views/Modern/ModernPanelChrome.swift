import SwiftUI

// MARK: - Header (136a, 136b)

/// 「Vibe Usage」 (with 「发现更新」 when Sparkle found one) on the left;
/// 「网页版 ↗」「排行榜 ↗」 (they open the website) and 「设置」 on the right.
struct ModernHeaderBar: View {
    @Environment(AppState.self) private var appState
    let hasUpdate: Bool
    let checkForUpdates: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(AppConfig.displayName)
                .font(ModernTheme.text(13, .semibold))
                .tracking(-0.13)
                .foregroundStyle(ModernTheme.text)
            if hasUpdate {
                Button(action: checkForUpdates) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                        Text("发现更新")
                            .font(ModernTheme.text(11, .medium))
                    }
                    .foregroundStyle(ModernTheme.text)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                    .frame(height: 18)
                    .background(Capsule().fill(ModernTheme.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            HStack(spacing: 16) {
                webLink("网页版", path: "usage")
                webLink("排行榜", path: "rank")
                Button(action: openSettings) {
                    Text("设置").modernHitArea()
                }
                .buttonStyle(ModernTextButtonStyle(color: ModernTheme.secondaryText))
            }
            .font(ModernTheme.text(13))
        }
        .frame(height: 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.horizontal, ModernTheme.textInset)
    }

    private func webLink(_ title: String, path: String) -> some View {
        Button {
            if let url = appState.usageServer.url(for: path) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.8)
            }
            .modernHitArea()
        }
        .buttonStyle(ModernTextButtonStyle(color: ModernTheme.secondaryText))
    }
}

// MARK: - 概览 row (133)

/// 「概览」 with its lamp, the round buttons (filled in by the subscription
/// card ticket) and the gear that opens Settings → 订阅配额. Shown only with
/// two or more enabled subscriptions.
struct ModernSubscriptionRow: View {
    @Environment(AppState.self) private var appState
    let openQuotaSettings: () -> Void

    var body: some View {
        let isOverview = appState.modernPanel.focusedSubscription(enabled: appState.quotaCardProviders) == nil
        HStack(spacing: 0) {
            Button {
                appState.modernPanel.selectedSubscription = nil
            } label: {
                HStack(spacing: 7) {
                    ModernLamp(isOn: isOverview)
                    Text("概览")
                        .font(ModernTheme.text(13, isOverview ? .semibold : .medium))
                        .foregroundStyle(isOverview ? ModernTheme.text : ModernTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(ModernTheme.separator)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 12)

            // Round buttons, one per enabled subscription, go here.
            Spacer(minLength: 0)

            Button(action: openQuotaSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .frame(width: 14, height: 14)
                    .modernHitArea()
            }
            .buttonStyle(ModernIconButtonStyle(color: ModernTheme.tertiaryText))
            .help("打开订阅配额设置")
            .accessibilityLabel("打开订阅配额设置")
        }
        .frame(height: 34)
        .padding(.horizontal, ModernTheme.textInset)
        .padding(.bottom, 12)
    }
}

/// The 概览 lamp: a dark well with a glowing dot when 概览 is selected.
struct ModernLamp: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(ModernTheme.well)
                .overlay(
                    // `inset 0 1px 2px rgba(0,0,0,.8)`
                    Circle()
                        .stroke(Color.black.opacity(0.8), lineWidth: 2)
                        .blur(radius: 1)
                        .offset(y: 1)
                        .clipShape(Circle())
                )
                .shadow(color: .white.opacity(0.06), radius: 0, x: 0, y: 1)
            Circle()
                .fill(isOn ? ModernTheme.lampOn : ModernTheme.lampOff)
                .frame(width: 6, height: 6)
                .shadow(color: isOn ? ModernTheme.text.opacity(0.75) : .clear, radius: 2.5)
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - Footer (136c–136j)

/// 「展开详情 / 收起详情」 on the left; 「同步用量」 (usage only, never quotas)
/// and the quit icon on the right. Without a linked account only the quit
/// icon remains.
struct ModernFooterBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            if appState.isConfigured {
                Button {
                    appState.modernPanel.detailsExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(appState.modernPanel.detailsExpanded ? "收起详情" : "展开详情")
                            .font(ModernTheme.text(13))
                            .fixedSize()
                        Image(systemName: appState.modernPanel.detailsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(0.7)
                    }
                    .modernHitArea()
                }
                .buttonStyle(ModernTextButtonStyle(color: ModernTheme.text))
            }

            Spacer(minLength: 12)

            if appState.isConfigured {
                ModernSyncButton()
                Rectangle()
                    .fill(ModernTheme.separator)
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 10)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(width: 12, height: 12)
                    .modernHitArea()
            }
            .buttonStyle(ModernIconButtonStyle(color: ModernTheme.secondaryText))
            .help("退出 \(AppConfig.displayName)")
            .accessibilityLabel("退出 \(AppConfig.displayName)")
        }
        .font(ModernTheme.text(11))
        .foregroundStyle(ModernTheme.secondaryText)
        .frame(height: 18)
        .padding(.vertical, 10)
        .padding(.horizontal, ModernTheme.textInset)
    }
}

/// What 「同步用量」 says (136c, 136e–136g).
enum ModernSyncLabel: Equatable {
    case syncing
    /// 「同步出错」 + a one-line reason + 「重试」; `detail` is the full message.
    case failed(reason: String, detail: String)
    /// 「26 分钟前同步」: the number is set in the mono face.
    case synced(number: String?, text: String)
    case never

    static func make(status: SyncStatus, lastSuccess: Date?, now: Date) -> Self {
        switch status {
        case .syncing:
            return .syncing
        case .error(let message):
            var reason = message
            if reason.hasPrefix("同步失败: ") { reason.removeFirst("同步失败: ".count) }
            reason = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return .failed(reason: reason.trimmingCharacters(in: .whitespaces), detail: message)
        case .idle, .success:
            guard let lastSuccess else { return .never }
            let relative = Formatters.formatRelativeTime(lastSuccess, relativeTo: now)
            let digits = relative.prefix(while: \.isNumber)
            return digits.isEmpty
                ? .synced(number: nil, text: relative + "同步")
                : .synced(number: String(digits), text: String(relative.dropFirst(digits.count)) + "同步")
        }
    }
}

/// 「同步用量」: runs the usage sync only. Quotas have their own button on
/// the 订阅配额 card.
struct ModernSyncButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Re-read the relative time while the panel is up. Periodic from now
        // rather than `.everyMinute`, whose dates sit on the minute boundary
        // and would read a minute short.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let label = ModernSyncLabel.make(
                status: appState.syncStatus, lastSuccess: appState.lastSuccessfulSyncAt, now: context.date
            )
            Button {
                Task { await appState.triggerSync() }
            } label: {
                content(label).modernHitArea()
            }
            .buttonStyle(ModernTextButtonStyle(color: ModernTheme.secondaryText))
            .disabled(label == .syncing)
            .help(help(label))
        }
    }

    @ViewBuilder
    private func content(_ label: ModernSyncLabel) -> some View {
        HStack(spacing: 6) {
            switch label {
            case .syncing:
                ModernSpinner(size: 12)
                Text("同步中")
            case .failed(let reason, _):
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ModernTheme.red)
                    .frame(width: 12, height: 12)
                Text("同步出错").foregroundStyle(ModernTheme.strongText).fixedSize()
                // Only the reason gives way when it is long; the full message
                // is the tooltip.
                if !reason.isEmpty {
                    Text(reason).lineLimit(1).truncationMode(.tail)
                }
                Text("重试")
                    .font(ModernTheme.text(11, .medium))
                    .foregroundStyle(ModernTheme.text)
                    .padding(.leading, 2)
                    .fixedSize()
            case .synced(let number, let text):
                syncIcon
                HStack(spacing: 0) {
                    if let number { Text(number).font(ModernTheme.mono(11)) }
                    Text(text)
                }
            case .never:
                syncIcon
                Text("还没同步过")
            }
        }
    }

    private var syncIcon: some View {
        Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 12, height: 12)
    }

    private func help(_ label: ModernSyncLabel) -> String {
        if case .failed(_, let detail) = label { return detail }
        return "同步用量"
    }
}

// MARK: - Small parts

/// The design's spinner: a faint ring with a bright quarter arc, turning.
/// The angle comes from the clock, not from a repeating implicit animation,
/// which would also animate the spinner's position when it appears.
struct ModernSpinner: View {
    var size: CGFloat
    @State private var start = Date()

    var body: some View {
        let lineWidth = size * 2.4 / 24
        let inset = size * 3.5 / 24
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSince(start) / 0.9
            ZStack {
                Circle().stroke(ModernTheme.text.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(ModernTheme.text, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turns.truncatingRemainder(dividingBy: 1) * 360))
            }
            .padding(inset)
        }
        .frame(width: size, height: size)
    }
}

/// Text buttons brighten to the primary color under the pointer.
struct ModernTextButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        ModernHoverLabel(configuration: configuration, color: color)
    }
}

/// Icon-only buttons: same hover rule.
typealias ModernIconButtonStyle = ModernTextButtonStyle

private struct ModernHoverLabel: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovered && isEnabled ? ModernTheme.text : color)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// A few points of extra click target around small text and icons,
    /// without moving them.
    func modernHitArea() -> some View {
        padding(4).contentShape(Rectangle()).padding(-4)
    }
}
