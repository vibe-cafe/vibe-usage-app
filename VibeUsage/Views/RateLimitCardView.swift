import SwiftUI
import AppKit

/// Side-by-side subscription quota cards for Codex (left) and Claude (right).
/// Each card stays the same size regardless of state to keep the row balanced.
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let codex = snapshot(for: .codex)
        let claude = snapshot(for: .claudeCode)

        if shouldShowCard(codex) || shouldShowCard(claude) {
            // Grid gives both row cells the same height by default — exactly the
            // "top-align content but match outer height" behaviour we want.
            // HStack alone keeps each cell at its intrinsic height which leaves
            // a noticeable height gap when content amounts differ.
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ProviderCard(snapshot: codex)
                    ProviderCard(snapshot: claude)
                }
            }
        }
    }

    private func snapshot(for provider: ProviderRateLimit.Provider) -> ProviderRateLimit {
        appState.rateLimits.first(where: { $0.provider == provider })
            ?? ProviderRateLimit(provider: provider, status: .noData)
    }

    /// Hide a card entirely if the provider has nothing to surface (e.g. Codex
    /// not installed at all). Always show Claude so the enable/disable affordance
    /// stays discoverable.
    private func shouldShowCard(_ snap: ProviderRateLimit) -> Bool {
        if snap.provider == .claudeCode { return true }
        return snap.status != .noData
    }
}

// MARK: - Per-provider card

private struct ProviderCard: View {
    @Environment(AppState.self) private var appState
    let snapshot: ProviderRateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: snapshot.provider)
                .frame(width: 14, height: 14)
            Text(snapshot.provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if let label = snapshot.planLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(white: 0.16))
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.status {
        case .ok:
            quotaRows
        case .disabled:
            disabledContent
        case .unauthorized:
            messageContent(text: "未授权或登录已过期", action: "重试")
        case .error(let msg):
            messageContent(text: msg, action: "重试")
        case .noData:
            // Reached only for Codex when there is no installed-but-unused state we want to show.
            EmptyView()
        }
    }

    @ViewBuilder
    private var quotaRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let win = snapshot.fiveHour {
                QuotaRow(label: "5h", window: win)
            }
            if let win = snapshot.sevenDay {
                QuotaRow(label: "7d", window: win)
            }
            if snapshot.fiveHour == nil && snapshot.sevenDay == nil {
                Text("暂无配额数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
    }

    private var disabledContent: some View {
        HStack(spacing: 8) {
            Text("授权并点击「始终允许」查看")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                print("[rate-limit] enable button tapped")
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

    private func messageContent(text: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                Task { await appState.refreshAllRateLimits() }
            } label: {
                Text(action)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Quota row

private struct QuotaRow: View {
    let label: String
    let window: RateLimitWindow
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                ProgressBar(value: window.utilization)
                    .frame(height: 6)
                ProgressBar(value: elapsedPercent ?? 0, fill: Color(white: 0.42), background: Color(white: 0.14))
                    .frame(height: 3)
                    .opacity(elapsedPercent != nil ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            // Float the rich tooltip above the bar stack on hover. Match the
            // BarChart's aesthetic: black panel, subtle stroke, shadow,
            // multi-color rows. Sized via .fixedSize so the tooltip extends
            // beyond the row bounds without clipping the layout.
            .overlay(alignment: .topLeading) {
                if isHovered {
                    TooltipView(
                        title: tooltipTitle,
                        tokenPercentText: percentText,
                        tokenColor: barColor,
                        elapsedPercentText: elapsedPercentText,
                        remainingText: remainingText
                    )
                    .fixedSize()
                    .offset(y: -tooltipOffset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)

            Text(percentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var percentText: String {
        if window.utilization < 0.05 { return "0%" }
        if window.utilization < 1 { return String(format: "%.1f%%", window.utilization) }
        return "\(Int(window.utilization.rounded()))%"
    }

    /// What fraction of the rolling window has elapsed since it started.
    /// Hidden when we lack either the duration or the reset target — falls back
    /// to a transparent 0-width bar to keep vertical alignment between rows.
    private var elapsedPercent: Double? {
        guard let resetsAt = window.resetsAt,
              let duration = window.windowDuration,
              duration > 0
        else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSinceNow)
        let elapsed = max(0, duration - remaining)
        return min(100, elapsed / duration * 100)
    }

    private var elapsedPercentText: String? {
        guard let p = elapsedPercent else { return nil }
        if p < 0.05 { return "0%" }
        if p < 1 { return String(format: "%.1f%%", p) }
        return "\(Int(p.rounded()))%"
    }

    private var remainingText: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        return Formatters.formatTimeUntil(resetsAt)
    }

    private var tooltipTitle: String {
        switch label {
        case "5h": return "5 小时窗口"
        case "7d": return "7 天窗口"
        default:   return label
        }
    }

    private var tooltipOffset: CGFloat {
        // Approx tooltip height (3 rows × 14 line-height + 16 vertical pad +
        // a few pts of breathing room). Pre-computed so the floating panel
        // hovers just above the bar stack without overlap.
        elapsedPercentText != nil ? 76 : 56
    }

    private var barColor: Color { ProgressBar.color(for: window.utilization) }
}

// MARK: - Tooltip panel

private struct TooltipView: View {
    let title: String
    let tokenPercentText: String
    let tokenColor: Color
    let elapsedPercentText: String?
    let remainingText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)

            row(
                dotColor: tokenColor,
                label: "Token 用量",
                value: "已使用 \(tokenPercentText)",
                valueColor: tokenColor,
                valueWeight: .medium
            )

            if let elapsed = elapsedPercentText, let remaining = remainingText {
                row(
                    dotColor: Color(white: 0.55),
                    label: "时间",
                    value: "已过去 \(elapsed) · 剩余 \(remaining)",
                    valueColor: Color(white: 0.82),
                    valueWeight: .regular
                )
            } else {
                row(
                    dotColor: Color(white: 0.55),
                    label: "时间",
                    value: "未知",
                    valueColor: Color(white: 0.5),
                    valueWeight: .regular
                )
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black)
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
    }

    private func row(dotColor: Color, label: String, value: String, valueColor: Color, valueWeight: Font.Weight) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(Color(white: 0.55))
            Text(value)
                .foregroundStyle(valueColor)
                .fontWeight(valueWeight)
        }
    }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let value: Double
    var fill: Color? = nil       // nil → derive from utilization (token bar default)
    var background: Color = Color(white: 0.18)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(background)
                Capsule()
                    .fill(fill ?? Self.color(for: value))
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100))
            }
        }
    }

    static func color(for utilization: Double) -> Color {
        switch utilization {
        case ..<70:    return Color(white: 0.85)
        case 70..<90:  return Color(red: 0.96, green: 0.62, blue: 0.04)
        default:       return Color(red: 0.94, green: 0.27, blue: 0.27)
        }
    }
}

// MARK: - Provider icon

private struct ProviderIcon: View {
    let provider: ProviderRateLimit.Provider

    var body: some View {
        if let nsImage = ProviderIcon.image(for: provider) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: provider == .codex ? "terminal" : "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.6))
        }
    }

    /// Cache so we don't re-decode the SVG on every render.
    private static var cache: [ProviderRateLimit.Provider: NSImage] = [:]

    private static func image(for provider: ProviderRateLimit.Provider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let resource: String
        switch provider {
        case .codex:      resource = "codex-icon"
        case .claudeCode: resource = "claude-icon"
        }
        // Try PNG first (Claude ships its product mark as PNG), fall back to SVG.
        let url = Bundle.appResources.url(forResource: resource, withExtension: "png")
            ?? Bundle.appResources.url(forResource: resource, withExtension: "svg")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        cache[provider] = img
        return img
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
}
