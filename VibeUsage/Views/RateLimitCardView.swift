import SwiftUI

/// Subscription quota card. Renders one row per rate-limit window.
/// Provider icon + label are shown on the first row of each group only;
/// subsequent rows under the same provider keep that area blank for alignment.
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    private var visible: [ProviderRateLimit] {
        // Hide a provider entirely if it has nothing to show. `.disabled` for Claude
        // still renders (it's how we surface the enable button); `.noData` for Codex
        // (no recent sessions) is hidden so users without Codex installed don't see it.
        appState.rateLimits.filter { snapshot in
            switch snapshot.status {
            case .noData: return false
            default: return true
            }
        }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { snapshot in
                    ProviderRows(snapshot: snapshot)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.09))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
        }
    }
}

// MARK: - Per-provider rows

private struct ProviderRows: View {
    @Environment(AppState.self) private var appState
    let snapshot: ProviderRateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch snapshot.status {
            case .ok:
                renderWindows()
            case .disabled:
                disabledRow
            case .unauthorized:
                statusRow(message: "未授权或登录已过期", action: "重试授权")
            case .error(let msg):
                statusRow(message: "暂时无法获取：\(msg)", action: "重试")
            case .noData:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func renderWindows() -> some View {
        let rows = collectRows()
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            QuotaRow(
                providerLabel: index == 0 ? snapshot.provider.displayName : nil,
                providerIcon: index == 0 ? snapshot.provider.iconName : nil,
                window: row.window,
                value: row.value
            )
        }
    }

    private struct WindowRow {
        var window: String  // "5 小时" / "7 天"
        var value: RateLimitWindow
    }

    private func collectRows() -> [WindowRow] {
        var rows: [WindowRow] = []
        if let win = snapshot.fiveHour { rows.append(.init(window: "5 小时", value: win)) }
        if let win = snapshot.sevenDay { rows.append(.init(window: "7 天", value: win)) }
        return rows
    }

    private var disabledRow: some View {
        HStack(spacing: 8) {
            ProviderBadge(name: snapshot.provider.displayName, icon: snapshot.provider.iconName)
            Text("点击启用监控")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
            Spacer()
            Button {
                Task { await appState.enableClaudeRateLimit() }
            } label: {
                Text("启用")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func statusRow(message: String, action: String) -> some View {
        HStack(spacing: 8) {
            ProviderBadge(name: snapshot.provider.displayName, icon: snapshot.provider.iconName)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
            Spacer()
            Button {
                Task { await appState.refreshRateLimits() }
            } label: {
                Text(action)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Single quota row

private struct QuotaRow: View {
    let providerLabel: String?
    let providerIcon: String?
    let window: String
    let value: RateLimitWindow

    var body: some View {
        HStack(spacing: 8) {
            // Provider area — icon + name shown on first row only, blank
            // afterwards to keep alignment without repeating the badge.
            if let label = providerLabel, let icon = providerIcon {
                ProviderBadge(name: label, icon: icon)
            } else {
                Color.clear.frame(width: providerColumnWidth, height: 1)
            }

            Text(window)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: value.utilization)
                .frame(height: 6)

            Text(percentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 38, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var providerColumnWidth: CGFloat { 70 }

    private var percentText: String {
        if value.utilization < 0.05 { return "0%" }
        if value.utilization < 1 { return String(format: "%.1f%%", value.utilization) }
        return "\(Int(value.utilization.rounded()))%"
    }

    private var resetText: String {
        guard let resetsAt = value.resetsAt else { return "—" }
        return Formatters.formatTimeUntil(resetsAt)
    }

    private var barColor: Color { ProgressBar.color(for: value.utilization) }
}

// MARK: - Provider badge (icon + name)

private struct ProviderBadge: View {
    let name: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(icon, bundle: .module)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 14, height: 14)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.78))
        }
        .frame(width: 70, alignment: .leading)
    }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.16))
                Capsule()
                    .fill(Self.color(for: value))
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100))
            }
        }
    }

    static func color(for utilization: Double) -> Color {
        switch utilization {
        case ..<70:    return Color(white: 0.85)                            // neutral white
        case 70..<90:  return Color(red: 0.96, green: 0.62, blue: 0.04)     // amber
        default:       return Color(red: 0.94, green: 0.27, blue: 0.27)     // red
        }
    }
}

// MARK: - Provider helpers

private extension ProviderRateLimit.Provider {
    var displayName: String {
        switch self {
        case .codex:      return "Codex"
        case .claudeCode: return "Claude"
        }
    }
    var iconName: String {
        switch self {
        case .codex:      return "CodexIcon"
        case .claudeCode: return "ClaudeIcon"
        }
    }
}
