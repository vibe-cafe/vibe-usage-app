import SwiftUI

/// Subscription quota card for AI coding tools (Codex + Claude Code).
///
/// Hidden when both providers report `.noData` — only renders if at least one
/// provider has data, an auth issue, or a transient error to surface.
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    private var visible: [ProviderRateLimit] {
        appState.rateLimits.filter { $0.status != .noData }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(visible) { snapshot in
                    ProviderSection(snapshot: snapshot)
                }
            }
            .padding(14)
            .background(Color(white: 0.09))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
        }
    }
}

// MARK: - Provider section

private struct ProviderSection: View {
    let snapshot: ProviderRateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))
                Text(snapshot.provider.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.78))
                Spacer()
                if let fetched = snapshot.fetchedAt {
                    Text(Formatters.formatRelativeTime(fetched))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.38))
                }
            }

            switch snapshot.status {
            case .ok:
                progressRows
            case .unauthorized:
                statusBanner(text: "未登录或未授权 keychain — 在 Claude Code 重新登录后可用")
            case .error(let msg):
                statusBanner(text: "暂时无法获取：\(msg)")
            case .noData:
                EmptyView()
            }
        }
    }

    private var icon: String {
        switch snapshot.provider {
        case .codex:      return "terminal"
        case .claudeCode: return "sparkles"
        }
    }

    @ViewBuilder
    private var progressRows: some View {
        if let win = snapshot.fiveHour {
            QuotaRow(label: "5 小时", window: win)
        }
        if let win = snapshot.sevenDay {
            QuotaRow(label: "7 天", window: win)
        }
        if let win = snapshot.sevenDayOpus {
            QuotaRow(label: "Opus 7 天", window: win)
        }
        if let win = snapshot.sevenDaySonnet {
            QuotaRow(label: "Sonnet 7 天", window: win)
        }
        if let extra = snapshot.extraUsage, extra.isEnabled, extra.limit > 0 {
            ExtraUsageRow(extra: extra)
        }
    }

    private func statusBanner(text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(white: 0.55))
            .padding(.vertical, 4)
    }
}

// MARK: - Quota row

private struct QuotaRow: View {
    let label: String
    let window: RateLimitWindow

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 64, alignment: .leading)

            ProgressBar(value: window.utilization)
                .frame(height: 6)

            Text(percentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 44, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 86, alignment: .trailing)
        }
    }

    private var percentText: String {
        if window.utilization < 0.05 { return "0%" }
        if window.utilization < 1 { return String(format: "%.1f%%", window.utilization) }
        return "\(Int(window.utilization.rounded()))%"
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "—" }
        return Formatters.formatTimeUntil(resetsAt) + " 后重置"
    }

    private var barColor: Color {
        ProgressBar.color(for: window.utilization)
    }
}

// MARK: - Extra usage (Claude pay-as-you-go)

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack(spacing: 10) {
            Text("额外配额")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 64, alignment: .leading)

            ProgressBar(value: percent)
                .frame(height: 6)

            Text(amountText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.55))
                .frame(width: 134, alignment: .trailing)
        }
    }

    private var percent: Double {
        guard extra.limit > 0 else { return 0 }
        return min(100, extra.spend / extra.limit * 100)
    }

    private var amountText: String {
        String(format: "$%.2f / $%.2f", extra.spend, extra.limit)
    }
}

// MARK: - Progress bar primitive

private struct ProgressBar: View {
    let value: Double  // 0-100

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
        case ..<70:  return Color(white: 0.85)                              // neutral white
        case 70..<90: return Color(red: 0.96, green: 0.62, blue: 0.04)      // amber
        default:      return Color(red: 0.94, green: 0.27, blue: 0.27)      // red
        }
    }
}
