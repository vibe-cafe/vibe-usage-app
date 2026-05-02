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
            HStack(alignment: .top, spacing: 8) {
                ProviderCard(snapshot: codex)
                ProviderCard(snapshot: claude)
            }
            .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 96)
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
            Button {
                Task { await appState.enableClaudeRateLimit() }
            } label: {
                Text("启用监控")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Text("首次需 keychain 授权")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.4))
                .lineLimit(1)
            Spacer(minLength: 0)
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

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 20, alignment: .leading)

            ProgressBar(value: window.utilization)
                .frame(height: 6)

            Text(percentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 32, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var percentText: String {
        if window.utilization < 0.05 { return "0%" }
        if window.utilization < 1 { return String(format: "%.1f%%", window.utilization) }
        return "\(Int(window.utilization.rounded()))%"
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "—" }
        return Formatters.formatTimeUntil(resetsAt)
    }

    private var barColor: Color { ProgressBar.color(for: window.utilization) }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.18))
                Capsule()
                    .fill(Self.color(for: value))
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
