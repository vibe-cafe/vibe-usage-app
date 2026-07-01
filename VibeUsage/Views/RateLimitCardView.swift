import SwiftUI
import AppKit

/// Side-by-side subscription quota cards for Codex (left) and Claude (right).
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let codex = snapshot(for: .codex)
        let claude = snapshot(for: .claudeCode)
        let showCodex = shouldShowCard(codex)
        let showClaude = shouldShowCard(claude)

        if showCodex && showClaude {
            // Grid keeps both row cells the same height by default — needed
            // for visual symmetry when one provider has more rows than the
            // other (e.g. free Codex with only 7d, vs Claude Pro with 5h+7d).
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ProviderCard(snapshot: codex)
                    ProviderCard(snapshot: claude)
                }
            }
        } else if showCodex {
            ProviderCard(snapshot: codex)
        } else if showClaude {
            ProviderCard(snapshot: claude)
        } else {
            noticeBar
        }
    }

    private func snapshot(for provider: ProviderRateLimit.Provider) -> ProviderRateLimit {
        appState.rateLimits.first(where: { $0.provider == provider })
            ?? ProviderRateLimit(provider: provider, status: .noData)
    }

    /// Hide a card only when the provider has produced no signal at all
    /// (`.noData`). `.disabled` / `.unauthorized` / `.error` all carry an
    /// actionable affordance and stay visible. When BOTH sides are `.noData`,
    /// `body` swaps the row for `noticeBar` so the empty state is whisper-quiet.
    private func shouldShowCard(_ snap: ProviderRateLimit) -> Bool {
        snap.status != .noData
    }

    /// Single-line whisper shown when neither Codex nor Claude has any data.
    /// Mirrors the generic "feature exists; use a tool to populate" hint without
    /// reserving the full card row's vertical space.
    private var noticeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("支持 Codex / Claude 订阅配额监控")
                .font(.system(size: 11))
        }
        .foregroundStyle(Color(white: 0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// One slot in the rows VStack: either a live `QuotaRow` or a placeholder
    /// for a window the plan covers but has no current data for. The case
    /// matters for the tooltip overlay — only `.live` rows have a hover key.
    private enum RowItem {
        case live(label: String, window: RateLimitWindow)
        case placeholder(label: String, message: String)

        var hoverLabel: String {
            switch self {
            case let .live(label, _): return label
            case let .placeholder(label, _): return label
            }
        }

        var liveWindow: RateLimitWindow? {
            if case let .live(_, window) = self { return window }
            return nil
        }
    }

    /// Visible rows in display order. Paid Codex plans always reserve the 5h
    /// slot — if utilization is unknown (no recent activity, so `parseWindow`
    /// dropped the expired window) we render a placeholder rather than letting
    /// the 7d row shift up and pose as 5h. Free Codex / Claude never get the
    /// 5h placeholder because those plans don't carry that window at all.
    private var visibleRows: [RowItem] {
        var out: [RowItem] = []
        if let w = snapshot.fiveHour {
            out.append(.live(label: "5h", window: w))
        } else if expectsFiveHourWindow {
            out.append(.placeholder(label: "5h", message: "近 5 小时无活动"))
        }
        if let w = snapshot.sevenDay { out.append(.live(label: "7d", window: w)) }
        return out
    }

    /// True only for paid Codex plans (Plus / Pro / Business), where Codex
    /// emits both `primary` and `secondary` windows in every `token_count`
    /// payload. Free-tier and Claude payloads don't carry a 5h window, so
    /// reserving the slot would just confuse users on those plans.
    private var expectsFiveHourWindow: Bool {
        guard snapshot.provider == .codex,
              let plan = snapshot.planLabel?.lowercased() else { return false }
        return plan == "plus" || plan == "pro" || plan == "business"
    }

    @ViewBuilder
    private var quotaRows: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
                    .frame(height: rowHeight)
            }
            if rows.isEmpty {
                Text("暂无订阅配额数据")
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
               let idx = rows.firstIndex(where: { $0.hoverLabel == hovered }),
               let win = rows[idx].liveWindow {
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

    @ViewBuilder
    private func rowView(_ row: RowItem) -> some View {
        switch row {
        case let .live(label, window):
            QuotaRow(label: label, window: window) { hovering in
                hoveredLabel = hovering ? label : (hoveredLabel == label ? nil : hoveredLabel)
            }
        case let .placeholder(label, message):
            EmptyQuotaRow(label: label, message: message)
        }
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

    /// Claude `.disabled` means the statusline capture hook isn't installed yet.
    /// The button installs it (a one-time edit to Claude Code's settings.json);
    /// thereafter reads are auth-free. Copy is kept to one plain-language line
    /// (matching the other states); an install failure replaces it inline.
    private var disabledContent: some View {
        HStack(spacing: 8) {
            Text(appState.claudeRateLimitInstallError ?? "读取 Claude 用量数据")
                .font(.system(size: 11))
                .foregroundStyle(
                    appState.claudeRateLimitInstallError != nil
                        ? Color(red: 0.94, green: 0.27, blue: 0.27)
                        : Color(white: 0.5)
                )
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                Task { await appState.setClaudeRateLimitEnabled(true) }
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

    /// Codex reports a true rolling window → we can show the secondary
    /// "% time elapsed" bar. Claude's payload only has an absolute reset
    /// instant (no window length), so `elapsedPercent` is nil; for it we
    /// drop the bar entirely and spell out the reset time as plain text.
    private var hasElapsed: Bool { window.elapsedPercent != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 20, alignment: .leading)

            if hasElapsed {
                // Codex: token bar + elapsed-time bar.
                VStack(alignment: .leading, spacing: 2) {
                    ProgressBar(value: window.utilization)
                        .frame(height: 6)
                    ProgressBar(
                        value: window.elapsedPercent ?? 0,
                        fill: Color(white: 0.42),
                        background: Color(white: 0.14)
                    )
                    .frame(height: 3)
                }
                .contentShape(Rectangle())
                .onHover { hovering in onHover(hovering) }

                Text(window.percentText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ProgressBar.color(for: window.utilization))
                    .frame(width: 36, alignment: .trailing)
            } else {
                // Claude: no window length to derive a time bar. The reset
                // countdown isn't shown inline (it churns every minute and read
                // as clutter, esp. right after a reset) — it lives in the hover
                // tooltip's "重置 · 剩余 X" row instead.
                ProgressBar(value: window.utilization)
                    .frame(height: 6)
                    .contentShape(Rectangle())
                    .onHover { hovering in onHover(hovering) }

                Text(window.percentText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ProgressBar.color(for: window.utilization))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: - Empty quota row

/// Placeholder for a window the plan covers but currently has no data for —
/// e.g. paid-Codex 5h after the user has been idle for >5h. Keeps the label
/// column aligned with `QuotaRow` so the 7d row doesn't visually shift into
/// the 5h slot. No progress bar, no hover state.
private struct EmptyQuotaRow: View {
    let label: String
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.4))
                .frame(width: 20, alignment: .leading)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            // Codex has both elapsed-% and remaining; Claude only has the
            // reset countdown (no window length). Show whatever we actually
            // have rather than collapsing the latter to "未知".
            if let elapsed = elapsedPercentText, let remaining = remainingText {
                row(
                    dotColor: Color(white: 0.55),
                    label: "时间",
                    value: "已过去 \(elapsed) · 剩余 \(remaining)",
                    valueColor: Color(white: 0.82),
                    valueWeight: .regular
                )
            } else if let remaining = remainingText {
                row(
                    dotColor: Color(white: 0.55),
                    label: "重置",
                    value: "剩余 \(remaining)",
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
