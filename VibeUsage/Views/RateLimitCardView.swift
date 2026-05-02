import SwiftUI
import AppKit

/// Side-by-side subscription quota cards for Codex (left) and Claude (right).
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let codex = snapshot(for: .codex)
        let claude = snapshot(for: .claudeCode)

        if shouldShowCard(codex) || shouldShowCard(claude) {
            // Grid keeps both row cells the same height by default — needed
            // for visual symmetry when one provider has more rows than the
            // other (e.g. free Codex with only 7d, vs Claude Pro with 5h+7d).
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

    /// Always show Claude (so the enable affordance stays discoverable).
    /// Hide Codex if there is no recent session data at all.
    private func shouldShowCard(_ snap: ProviderRateLimit) -> Bool {
        if snap.provider == .claudeCode { return true }
        return snap.status != .noData
    }
}

// MARK: - Per-provider card

private struct ProviderCard: View {
    @Environment(AppState.self) private var appState
    let snapshot: ProviderRateLimit

    /// Which window-label is currently hovered (`"5h"` / `"7d"`). Lifted to the
    /// card level so the tooltip can render as ONE overlay on the rows VStack
    /// instead of per-row — overlay paints after its parent's content, which
    /// gives us the correct stacking automatically without any zIndex hacks.
    /// (See `BarChartView` for the same pattern with multi-bar tooltips.)
    @State private var hoveredLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        // Compose the rounded fill and the border stroke into a single
        // BACKGROUND layer. If the stroke were a separate `.overlay` it
        // would paint after (i.e. on top of) the card's content — the
        // bottom-edge stroke would then cut through any tooltip that
        // overflows past the card's lower border. Putting both inside
        // `.background` keeps them entirely behind the content.
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(white: 0.16), lineWidth: 1)
                )
        )
    }

    // MARK: Header

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

    // MARK: Content (varies by status)

    @ViewBuilder
    private var content: some View {
        switch snapshot.status {
        case .ok:           quotaRows
        case .disabled:     disabledContent
        case .unauthorized: messageContent(text: "未授权或登录已过期", action: "重试")
        case .error(let m): messageContent(text: m, action: "重试")
        case .noData:       EmptyView()
        }
    }

    /// Visible quota rows in display order, paired with the label we use as
    /// the hover key. Computing this once lets us share between the rows
    /// VStack and the tooltip overlay.
    private var visibleRows: [(label: String, window: RateLimitWindow)] {
        var out: [(String, RateLimitWindow)] = []
        if let w = snapshot.fiveHour { out.append(("5h", w)) }
        if let w = snapshot.sevenDay { out.append(("7d", w)) }
        return out
    }

    @ViewBuilder
    private var quotaRows: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.label) { _, row in
                QuotaRow(label: row.label, window: row.window) { hovering in
                    hoveredLabel = hovering ? row.label : (hoveredLabel == row.label ? nil : hoveredLabel)
                }
                .frame(height: rowHeight)
            }
            if rows.isEmpty {
                Text("暂无配额数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        // The tooltip overlay attached HERE — at the rows VStack — paints
        // above all child rows as a natural property of how SwiftUI composes
        // overlays (overlay always renders after its underlying content,
        // so it cannot be obscured by sibling rows). No zIndex needed.
        .overlay(alignment: .topLeading) {
            if let hovered = hoveredLabel,
               let idx = rows.firstIndex(where: { $0.label == hovered }) {
                let win = rows[idx].window
                TooltipView(
                    title: tooltipTitle(for: hovered),
                    tokenPercentText: win.percentText,
                    tokenColor: ProgressBar.color(for: win.utilization),
                    elapsedPercentText: win.elapsedPercentText,
                    remainingText: win.remainingText
                )
                .fixedSize()
                .offset(y: tooltipOffsetY(rowIndex: idx))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredLabel)
    }

    // Fixed row metrics so the tooltip can be positioned deterministically.
    private var rowHeight: CGFloat { 16 }
    private var rowSpacing: CGFloat { 6 }

    /// Y-offset where the tooltip's top-leading corner should sit, measured
    /// from the rows-VStack top. Places the tooltip 6pt below the bottom
    /// edge of the hovered row.
    private func tooltipOffsetY(rowIndex: Int) -> CGFloat {
        let bottomOfRow = CGFloat(rowIndex + 1) * rowHeight + CGFloat(rowIndex) * rowSpacing
        return bottomOfRow + 6
    }

    private func tooltipTitle(for label: String) -> String {
        switch label {
        case "5h": return "5 小时窗口"
        case "7d": return "7 天窗口"
        default:   return label
        }
    }

    // MARK: Disabled / error states

    private var disabledContent: some View {
        HStack(spacing: 8) {
            Text("授权并点击「始终允许」查看")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
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

/// Pure presentation: bars + label + percent. No tooltip / hover state
/// owned here — the parent ProviderCard observes hover through `onHover`
/// and renders the tooltip at its own layer.
private struct QuotaRow: View {
    let label: String
    let window: RateLimitWindow
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                ProgressBar(value: window.utilization)
                    .frame(height: 6)
                ProgressBar(
                    value: window.elapsedPercent ?? 0,
                    fill: Color(white: 0.42),
                    background: Color(white: 0.14)
                )
                .frame(height: 3)
                .opacity(window.elapsedPercent != nil ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering in onHover(hovering) }

            Text(window.percentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ProgressBar.color(for: window.utilization))
                .frame(width: 36, alignment: .trailing)
        }
    }
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
        // Same background-shape trick: rounded chrome without clipping.
        // (The tooltip itself doesn't host descendants that need to escape,
        // but staying consistent keeps the rendering simple.)
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
    var fill: Color? = nil
    var background: Color = Color(white: 0.18)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(background)
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

    private static var cache: [ProviderRateLimit.Provider: NSImage] = [:]

    private static func image(for provider: ProviderRateLimit.Provider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let resource: String
        switch provider {
        case .codex:      resource = "codex-icon"
        case .claudeCode: resource = "claude-icon"
        }
        let url = Bundle.appResources.url(forResource: resource, withExtension: "png")
            ?? Bundle.appResources.url(forResource: resource, withExtension: "svg")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        cache[provider] = img
        return img
    }
}

// MARK: - Window display helpers

/// Shared formatting so both the row UI and the tooltip read from the same
/// source of truth without duplicating arithmetic.
private extension RateLimitWindow {
    var percentText: String {
        if utilization < 0.05 { return "0%" }
        if utilization < 1 { return String(format: "%.1f%%", utilization) }
        return "\(Int(utilization.rounded()))%"
    }

    /// Fraction of the rolling window that has elapsed, derived from how
    /// much remains until reset. nil if either component is missing.
    var elapsedPercent: Double? {
        guard let resetsAt, let duration = windowDuration, duration > 0 else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSinceNow)
        let elapsed = max(0, duration - remaining)
        return min(100, elapsed / duration * 100)
    }

    var elapsedPercentText: String? {
        guard let p = elapsedPercent else { return nil }
        if p < 0.05 { return "0%" }
        if p < 1 { return String(format: "%.1f%%", p) }
        return "\(Int(p.rounded()))%"
    }

    var remainingText: String? {
        guard let resetsAt else { return nil }
        return Formatters.formatTimeUntil(resetsAt)
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
