import SwiftUI
import AppKit

/// Subscription quota section with local discovery, a product selector, and
/// provider-neutral cards. Selection order is card order.
struct RateLimitCardView: View {
    @Environment(AppState.self) private var appState

    /// Fixed card width. Two cards plus the 8pt gap fill the popover's content
    /// box exactly ((520 − 2×16 padding − 8) / 2), so the familiar two-card row
    /// is unchanged; a third product scrolls instead of squeezing every card
    /// narrower than its meters and labels can render.
    static let cardWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader

            switch Self.sectionContent(selected: appState.selectedQuotaProviders) {
            case let .cards(providers): cards(providers)
            case .notice: noticeBar
            }
        }
    }

    /// What the section shows under the header. Cards are one-per-product
    /// inside a horizontal scroller — an enabled product is never dropped, and
    /// the section never folds into a single generic line just because every
    /// card happens to be empty. The notice survives only for "you enabled
    /// nothing", where it doubles as the hint for the selector beside it.
    enum SectionContent: Equatable {
        case cards([ProviderRateLimit.Provider])
        case notice
    }

    static func sectionContent(
        selected: [ProviderRateLimit.Provider]
    ) -> SectionContent {
        selected.isEmpty ? .notice : .cards(selected)
    }

    /// One card per selected product, in selection order, inside a horizontal
    /// scroller. A product the user enabled must always show its own state,
    /// because a collapsed section reads as "this feature is off" precisely
    /// when the user wants to know why nothing is shown.
    private func cards(_ providers: [ProviderRateLimit.Provider]) -> some View {
        ScrollView(.horizontal, showsIndicators: providers.count > 2) {
            // Grid, not HStack: one row's cards share the tallest card's
            // height, so a provider showing fewer meters or an error message
            // still aligns with its neighbours instead of ending short.
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ForEach(providers, id: \.self) { provider in
                        ProviderCard(snapshot: snapshot(for: provider))
                            .frame(width: Self.cardWidth, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("订阅配额")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.72))
            Spacer()
            productSelector
        }
    }

    private var productSelector: some View {
        Menu {
            ForEach(appState.quotaProducts) { product in
                let selected = appState.isQuotaProviderSelected(product.provider)
                Button {
                    Task {
                        await appState.setQuotaProductSelected(
                            product.provider,
                            selected: !selected
                        )
                    }
                } label: {
                    Label(
                        "\(product.displayName) · \(appState.quotaProductStatusText(product))",
                        systemImage: selected ? "checkmark" : "circle"
                    )
                }
                .disabled(!selected && !appState.canSelectQuotaProvider(product.provider))
            }

            Divider()
            Button("重新检测本机产品") {
                appState.rediscoverQuotaProducts()
            }
        } label: {
            HStack(spacing: 4) {
                Text("选择 \(appState.selectedQuotaProviders.count)")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Color(white: 0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(white: 0.11))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择要显示订阅配额的产品")
    }

    private func snapshot(for provider: ProviderRateLimit.Provider) -> ProviderRateLimit {
        appState.rateLimits.first(where: { $0.provider == provider })
            ?? ProviderRateLimit(provider: provider, status: .noData)
    }

    /// Shown only while the user has selected nothing at all — the selector
    /// stays reachable so a product can be added back.
    private var noticeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("自动识别本机产品；请选择要显示的产品")
                .font(.system(size: 11))
        }
        .foregroundStyle(Color(white: 0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Status line for an enabled product whose card has no meters to draw.
    /// Only ever states what the data channel actually reported: the live
    /// Codex endpoint's own reason (`emptyReason`), local detection, or —
    /// when neither exists — that nothing has been read yet. Never invents
    /// "used up" for a source that cannot tell.
    static func emptyStateText(for snapshot: ProviderRateLimit, isDetected: Bool) -> String {
        switch snapshot.emptyReason {
        case .limitReached:
            return "本期订阅配额已用满 · 等待额度重置"
        case .noWindow:
            return "当前没有生效的额度窗口"
        case nil:
            return isDetected
                ? "暂未读取到订阅配额数据"
                : "未检测到本机安装或登录"
        }
    }
}

// MARK: - Per-provider card

private struct ProviderCard: View {
    @Environment(AppState.self) private var appState
    let snapshot: ProviderRateLimit

    /// Which window-label is currently hovered (`"5h"` / `"7d"`). The card owns
    /// only the *state* — the tooltip itself is drawn by the popover's topmost
    /// layer (`QuotaTooltipPreferenceKey`), because the card sits inside the
    /// horizontal card scroller and the dashboard's vertical `ScrollView`, and
    /// both clip whatever leaves the card's bounds.
    @State private var hoveredLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if snapshot.status == .ok {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let note = footerNote(at: context.date) {
                        Text(note)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color(white: 0.38))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        // Compose the rounded fill and the border stroke into a single
        // BACKGROUND layer. If the stroke were a separate `.overlay` it
        // would paint after (i.e. on top of) the card's content — the
        // bottom-edge stroke would then cut through the last row.
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
            if let credits = snapshot.resetCreditsCount, credits > 0 {
                Text("重置券 ×\(credits)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.25))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.95, green: 0.72, blue: 0.25).opacity(0.12))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
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
        case .disabled:
            // No provider reaches this state any more: Claude used to sit here
            // until the user installed the statusline hook. Kept as a graceful
            // landing for a snapshot persisted by an older build.
            messageContent(text: "订阅配额未启用", action: "重试")
        case .unauthorized:
            if snapshot.provider == .zCode {
                messageContent(
                    text: "请在设置中配置 \(appState.zCodeQuotaRegion.apiKeyName)",
                    action: "重试"
                )
            } else if snapshot.provider == .kimiCode {
                // The shared CLI has already attempted Kimi's standard OAuth
                // refresh before this status reaches the app.
                messageContent(text: "请重新登录 Kimi Code 后重试", action: "重试")
            } else {
                messageContent(text: "请打开 \(snapshot.provider.displayName) 使用一次后重试", action: "重试")
            }
        case .retryableError:
            messageContent(text: "暂时无法读取订阅配额", action: "重试")
        case .error(let m): messageContent(text: m, action: "重试")
        case .noData:
            if isRefreshing {
                messageText("正在读取订阅配额…")
            } else if snapshot.provider == .cursor {
                messageText(cursorPendingText)
            } else {
                messageText(RateLimitCardView.emptyStateText(for: snapshot, isDetected: isProductDetected))
            }
        }
    }

    /// Local discovery result only — never a credential or network read. It
    /// separates "installed but nothing to show yet" from "not on this Mac".
    private var isProductDetected: Bool {
        appState.quotaProducts.first(where: { $0.provider == snapshot.provider })?.isDetected == true
    }

    private var cursorPendingText: String {
        isProductDetected
            ? "已识别 Cursor · 等待官方配额接口"
            : "未检测到 Cursor · 等待官方配额接口"
    }

    /// Quiet single-line status text for the non-meter card states.
    private func messageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(white: 0.5))
            .fixedSize(horizontal: false, vertical: true)
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

    /// All available meters in provider-defined priority order. Native readers
    /// still populate their typed fields, while future CLI adapters can supply
    /// arbitrary meters through `snapshot.meters`.
    private var allRows: [RowItem] {
        if !snapshot.meters.isEmpty {
            return QuotaMeterLayout.canonicalMeters(snapshot.meters).map {
                .live(label: $0.label, window: $0.window)
            }
        }

        var out: [RowItem] = []
        if let w = snapshot.fiveHour {
            out.append(.live(label: "5h", window: w))
        } else if expectsFiveHourWindow {
            // Two different truths behind a missing 5h window: the live
            // endpoint asserts the limit is switched off provider-side, while
            // a JSONL snapshot can only mean "no event carried it recently".
            out.append(.placeholder(
                label: "5h",
                message: snapshot.fiveHourNotEnforced ? "官方当前未启用" : "近 5 小时无活动"
            ))
        }
        if let w = snapshot.sevenDay { out.append(.live(label: "7d", window: w)) }
        if let w = snapshot.sevenDayOpus { out.append(.live(label: "Opus", window: w)) }
        if let w = snapshot.sevenDaySonnet { out.append(.live(label: "Sonnet", window: w)) }
        if let extra = snapshot.extraUsage, extra.isEnabled, extra.limit > 0 {
            out.append(.live(
                label: "额外",
                window: RateLimitWindow(utilization: extra.spend / extra.limit * 100)
            ))
        }
        return out
    }

    /// Cards remain compact even when a provider exposes model-specific or
    /// pay-as-you-go meters. The footer states how many details are folded.
    private var visibleRows: [RowItem] { Array(allRows.prefix(2)) }
    private var additionalMeterCount: Int { max(0, allRows.count - visibleRows.count) }

    /// True only for paid Codex plans (Plus / Pro / Business), where Codex
    /// emits both `primary` and `secondary` windows in every `token_count`
    /// payload. Free-tier and Claude payloads don't carry a 5h window, so
    /// reserving the slot would just confuse users on those plans.
    private var expectsFiveHourWindow: Bool {
        guard snapshot.provider == .codex,
              let plan = snapshot.planLabel?.lowercased() else { return false }
        return plan == "plus" || plan == "pro" || plan == "prolite" || plan == "business"
    }

    @ViewBuilder
    private var quotaRows: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
                    .frame(height: rowHeight)
                    // Hand the hovered row's values *and* its own rect up to
                    // the popover's topmost layer, which is the only place the
                    // tooltip can be drawn whole: everything from here to the
                    // panel edge is inside a clipping scroller. Only the
                    // hovered row publishes, so the payload is never ambiguous.
                    .anchorPreference(
                        key: QuotaTooltipPreferenceKey.self,
                        value: .bounds
                    ) { anchor in
                        guard row.hoverLabel == hoveredLabel,
                              let win = row.liveWindow
                        else { return nil }
                        return QuotaTooltipPayload(
                            key: "\(snapshot.provider.rawValue)-\(row.hoverLabel)",
                            title: tooltipTitle(for: row.hoverLabel),
                            tokenPercentText: win.percentText,
                            tokenColor: ProgressBar.color(for: win.utilization),
                            elapsedPercentText: win.elapsedPercentText,
                            remainingText: win.remainingText,
                            anchor: anchor
                        )
                    }
            }
            if rows.isEmpty {
                Text("暂无订阅配额数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
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

    private func tooltipTitle(for label: String) -> String {
        switch label {
        case "5h": return "5 小时窗口"
        case "7d": return "7 天窗口"
        default:   return label
        }
    }

    // MARK: Freshness / footer

    private var isRefreshing: Bool {
        appState.isRateLimitRefreshing(snapshot.provider)
    }

    /// Data older than this gets a 「数据截至」 note. Claude captures age
    /// whenever Claude Code is idle and JSONL fallbacks age with Codex — both
    /// are normal, so the threshold is generous enough not to nag about a
    /// snapshot from a coffee break, while a live fetch (dataAsOf ≈ now)
    /// never shows the note.
    private static let staleNoteThreshold: TimeInterval = 5 * 60

    /// One quiet tertiary line under the quota rows for stale-data context.
    /// Reset credits live beside the provider title so they never add a row.
    private func footerNote(at now: Date) -> String? {
        var notes: [String] = []
        if additionalMeterCount > 0 {
            notes.append("另有 \(additionalMeterCount) 项")
        }
        if let asOf = snapshot.dataAsOf,
           now.timeIntervalSince(asOf) > Self.staleNoteThreshold {
            notes.append("数据截至 \(Formatters.formatRelativeTime(asOf, relativeTo: now))")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    // MARK: Error states

    private func messageContent(text: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                Task { await retryProvider() }
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

    /// A card-level retry must touch only the failed provider. In particular,
    /// retrying Codex should not spawn a Claude subprocess, and retrying Claude
    /// should not issue an unrelated Codex network request.
    private func retryProvider() async {
        await appState.refreshRateLimit(for: snapshot.provider)
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 42, alignment: .leading)
                .help(label)

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
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tooltip layer

/// Everything the quota tooltip needs in order to draw itself, carried from the
/// hovered row up to the panel root: the formatted values plus an anchor for the
/// row's rect.
///
/// The tooltip is taller than the card and straddles the card's bottom edge, so
/// nothing between the row and the panel edge can draw it whole — the horizontal
/// card scroller and the dashboard's vertical `ScrollView` both clip their
/// content, and every section below the quota row paints after it. Routing the
/// payload up as a preference lets `PopoverView`'s root overlay (above every
/// scroller, card, and sibling in the panel) draw it instead.
struct QuotaTooltipPayload {
    /// Hovered-row identity, so a move between rows animates instead of
    /// snapping.
    let key: String
    let title: String
    let tokenPercentText: String
    let tokenColor: Color
    let elapsedPercentText: String?
    let remainingText: String?
    /// The hovered row's rect, resolved by the layer that draws the tooltip.
    let anchor: Anchor<CGRect>
}

/// Carries the hovered row's payload to the panel root. Only the hovered row
/// publishes one, so `reduce` keeps the single payload that matters.
struct QuotaTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: QuotaTooltipPayload? { nil }

    static func reduce(
        value: inout QuotaTooltipPayload?,
        nextValue: () -> QuotaTooltipPayload?
    ) {
        value = value ?? nextValue()
    }
}

/// Where a tooltip of a known size goes, relative to the row that opened it.
/// Plain arithmetic (like `MenuBarPanelGeometry`) so the panel-edge rules are
/// testable without rendering: hang below the row while the tooltip fits
/// there, flip above it when it does not, and never let either axis leave the
/// panel.
enum QuotaTooltipPlacement {
    /// Distance between the hovered row and the tooltip.
    static let gap: CGFloat = 6
    /// Smallest distance the tooltip keeps from the panel's edges.
    static let edgeInset: CGFloat = 8

    static func origin(
        rowRect: CGRect,
        tooltipSize: CGSize,
        containerSize: CGSize
    ) -> CGPoint {
        let maxX = max(edgeInset, containerSize.width - tooltipSize.width - edgeInset)
        let x = min(max(rowRect.minX, edgeInset), maxX)

        let below = rowRect.maxY + gap
        let above = rowRect.minY - gap - tooltipSize.height
        let fitsBelow = below + tooltipSize.height + edgeInset <= containerSize.height
        let maxY = max(edgeInset, containerSize.height - tooltipSize.height - edgeInset)
        let y = min(max(fitsBelow ? below : above, edgeInset), maxY)

        return CGPoint(x: x, y: y)
    }
}

/// Places the tooltip at `QuotaTooltipPlacement.origin`. A `Layout` measures the
/// real tooltip size before placing it, so the flip rule needs no guessed height
/// and no second layout pass.
private struct QuotaTooltipLayout: Layout {
    let rowRect: CGRect
    let containerSize: CGSize

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        // The layout *is* the panel-wide layer; the tooltip is placed inside it.
        containerSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let origin = QuotaTooltipPlacement.origin(
                rowRect: rowRect,
                tooltipSize: size,
                containerSize: bounds.size
            )
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

/// The tooltip, drawn by the panel root for whichever row is hovered. Content is
/// exactly the rows it always had; only the layer it renders in changed.
struct QuotaTooltipOverlay: View {
    let payload: QuotaTooltipPayload
    let rowRect: CGRect
    let containerSize: CGSize

    var body: some View {
        QuotaTooltipLayout(rowRect: rowRect, containerSize: containerSize) {
            TooltipView(
                title: payload.title,
                tokenPercentText: payload.tokenPercentText,
                tokenColor: payload.tokenColor,
                elapsedPercentText: payload.elapsedPercentText,
                remainingText: payload.remainingText
            )
            .fixedSize()
        }
        // Decorative only: the pointer must keep driving the row's hover and the
        // scrollers underneath.
        .allowsHitTesting(false)
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

/// Official provider artwork (28/56 px assets in the app resource bundle) with
/// a symbol fallback. Shared by the quota cards' headers and the Settings
/// product rows, so both surfaces resolve the same asset the same way.
struct ProviderIcon: View {
    let provider: ProviderRateLimit.Provider

    var body: some View {
        if let nsImage = ProviderIcon.image(for: provider) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: provider.fallbackSymbolName)
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
        case .kimiCode:   resource = "kimi-icon"
        case .zCode:      resource = "zcode-icon"
        case .grok:       resource = "grok-icon"
        case .cursor:     resource = "cursor-icon"
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

private extension ProviderRateLimit.Provider {
    var fallbackSymbolName: String {
        switch self {
        case .codex: return "terminal"
        case .claudeCode: return "sparkles"
        case .kimiCode: return "moon.stars"
        case .zCode: return "z.square"
        case .grok: return "bolt.horizontal.circle"
        case .cursor: return "cursorarrow.rays"
        }
    }
}
