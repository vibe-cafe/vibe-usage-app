import SwiftUI

// The body of the new panel's 订阅配额 card (design 131–133, #109): the
// overview of every enabled subscription, one subscription's detail, and the
// empty state. What to draw — counts, tones, comments, the tightest
// allowance, the rings, the row order — comes from `QuotaPanelDisplay`; this
// file only lays it out and formats numbers.

extension AppState {
    /// The new panel's quota values at `now`, from the same snapshots,
    /// Settings order and refresh state as everything else.
    func quotaPanelDisplay(now: Date) -> QuotaPanelDisplay {
        let enabled = quotaCardProviders
        return QuotaPanelDisplay(
            snapshots: rateLimits,
            enabled: enabled,
            selected: modernPanel.selectedSubscription,
            now: now,
            modelMeters: Dictionary(rateLimits.map { ($0.provider, $0.modelScopedMeters) }) { first, _ in first },
            refreshing: Set(enabled.filter(isRateLimitRefreshing)),
            detected: Set(quotaProducts.filter(\.isDetected).map(\.provider)),
            zCodeRegion: zCodeQuotaRegion
        )
    }
}

/// Hover and fold states for the off-screen renderer (`PanelSnapshotTests`),
/// which cannot move a pointer. Never set in the app.
struct ModernQuotaPreview: Equatable {
    var hoveredOverviewRow: ProviderRateLimit.Provider?
    var hoveredDetailRow: String?
    var expanded = false
}

extension EnvironmentValues {
    @Entry var modernQuotaPreview = ModernQuotaPreview()
}

/// How the card writes numbers and times. Formatting only.
enum ModernQuotaFormat {
    /// Remaining percent without the sign: 「12」, and 「<1」 for a sliver that
    /// is not used up (rounding it to 「0」 would read as 已用完).
    static func percent(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1" }
        return "\(Int(value.rounded()))"
    }

    /// 「够用到重置」 or 「约 30 分钟后用完」.
    static func prediction(_ prediction: QuotaPanelMeter.Prediction) -> String {
        switch prediction {
        case .untilReset: return "够用到重置"
        case .runsOutIn(let seconds): return "约 \(roughly(seconds))后用完"
        }
    }

    /// 「30 分钟」, 「3 小时」, 「2 天」.
    static func roughly(_ seconds: TimeInterval) -> String {
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded()))) 分钟" }
        let hours = Int((seconds / 3_600).rounded())
        if hours < 24 { return "\(hours) 小时" }
        return "\(max(1, Int((seconds / 86_400).rounded()))) 天"
    }

    /// When an allowance resets: the clock time within a day (「17:10」),
    /// else in days (「4天后」).
    static func reset(_ meter: QuotaPanelMeter) -> String? {
        guard let left = meter.timeUntilReset, let resetsAt = meter.resetsAt else { return nil }
        if left < 86_400 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: resetsAt)
        }
        return "\(max(1, Int((left / 86_400).rounded())))天后"
    }

    /// 「3 天 17 小时」, 「2 小时 5 分钟」, 「12 分钟」.
    static func duration(_ seconds: TimeInterval) -> String {
        // Days are told to the nearest hour, hours to the nearest minute.
        if seconds >= 86_400 - 1_800 {
            let hours = Int((seconds / 3_600).rounded())
            let days = hours / 24
            let rest = hours % 24
            return rest > 0 ? "\(days) 天 \(rest) 小时" : "\(days) 天"
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 { return rest > 0 ? "\(hours) 小时 \(rest) 分钟" : "\(hours) 小时" }
        return "\(minutes) 分钟"
    }

    /// The tooltip of an allowance row (132r), or nil when nothing is known.
    static func tooltip(for meter: QuotaPanelMeter, provider: ProviderRateLimit.Provider) -> ModernQuotaTooltip? {
        var lines: [ModernQuotaTooltip.Line] = []
        if let used = meter.usedPercent { lines.append(.init(label: "已使用", value: "\(percent(used))%")) }
        if let elapsed = meter.elapsed { lines.append(.init(label: "已过去", value: duration(elapsed))) }
        if let left = meter.timeUntilReset { lines.append(.init(label: "离重置", value: duration(left))) }
        for part in meter.breakdown {
            lines.append(.init(label: part.label, value: "\(percent(part.utilization))%"))
        }
        guard !lines.isEmpty else { return nil }
        let title = meter.windowDuration.map { "\(window($0))窗口" } ?? meter.label
        return ModernQuotaTooltip(id: "\(provider.rawValue)-\(meter.id)", title: title, lines: lines)
    }

    /// 「7 天」, 「5 小时」.
    private static func window(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400)) 天"
        }
        if seconds >= 3_600 { return "\(Int((seconds / 3_600).rounded())) 小时" }
        return "\(max(1, Int((seconds / 60).rounded()))) 分钟"
    }

    /// Width of the detail rows' label column: 28 pt (「5h」), wider for a
    /// named allowance (「Fable」 40 pt), measured on the number face's fixed
    /// advance.
    static func labelColumnWidth(_ labels: [String]) -> CGFloat {
        let widest = labels.map { approximateWidth($0, size: 11) }.max() ?? 0
        return max(28, (widest + 7).rounded(.up))
    }

    /// Width of a short label: Chinese characters are square, the number
    /// face advances 0.6 em, which also covers the Latin text face closely
    /// enough for a layout decision.
    static func approximateWidth(_ text: String, size: CGFloat) -> CGFloat {
        text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 0.6 * size : size) }
    }
}

// MARK: - Card body

/// What sits under the card's title row: the empty state (132f), one
/// subscription (131b–131d, 132g, 132i–132r), or the overview (131a, 132a–132e).
struct ModernQuotaCardBody: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    var body: some View {
        // The pace moves with the clock; a minute is finer than any comment.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let display = appState.quotaPanelDisplay(now: context.date)
            if display.isEmpty {
                ModernQuotaEmptyState { openSettings(focus: nil) }
            } else if let detail = display.detail {
                ModernQuotaDetail(
                    subscription: detail,
                    retry: { Task { await appState.refreshRateLimit(for: detail.provider) } },
                    openCursorSignIn: { openSettings(focus: .cursor) }
                )
                // A new subscription starts folded, without a hovered row.
                .id(detail.provider)
            } else {
                ModernQuotaOverview(overview: display.overview) { provider in
                    appState.modernPanel.selectedSubscription = provider
                }
            }
        }
    }

    private func openSettings(focus: ProviderRateLimit.Provider?) {
        SettingsWindowController.shared.show(
            appState: appState, updaterViewModel: updaterViewModel, destination: .quotas(focus: focus)
        )
    }
}

// MARK: - Empty (132f)

struct ModernQuotaEmptyState: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ModernBigNumber(value: "0", color: ModernTheme.secondaryText)
                Text("个订阅")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(height: 18)
            }
            .frame(width: ModernTheme.leadingColumnWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                Text("还没有要看的订阅")
                    .font(ModernTheme.text(13, .medium))
                    .foregroundStyle(ModernTheme.text)
                    .frame(height: 18)
                Text("在设置里打开后，这里会列出每家还剩多少。")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(minHeight: 16)
                    .padding(.top, 2)
                Button(action: openSettings) {
                    HStack(spacing: 7) {
                        Text("去设置").font(ModernTheme.text(13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(0.7)
                    }
                    .modernHitArea()
                }
                .buttonStyle(ModernTextButtonStyle(color: ModernTheme.text))
                .padding(.top, 12)
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .frame(height: 112, alignment: .top)
    }
}

/// 44 pt light number (the overview count, the empty state's 0).
struct ModernBigNumber: View {
    let value: String
    let color: Color
    var suffix: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(value)
                .font(ModernTheme.mono(44, .light))
                .tracking(-2.64)
                .foregroundStyle(color)
            if let suffix {
                Text(suffix)
                    .font(ModernTheme.mono(22, .light))
                    .tracking(-0.88)
                    .foregroundStyle(ModernTheme.secondaryText)
                    .padding(.leading, 2)
            }
        }
        // CSS `line-height: 1`: the 44 pt line box centers the face's taller
        // ascent and descent, which puts the baseline where the design has it.
        .frame(height: 44, alignment: .leading)
        .padding(.leading, -2)
    }
}

// MARK: - Overview (131a, 132a–132e, 132h)

struct ModernQuotaOverview: View {
    let overview: QuotaOverviewDisplay
    let select: (ProviderRateLimit.Provider) -> Void

    /// Four lines (four subscriptions, or three and 「其余 N 个」) fill the
    /// 148 pt ring height; two or three take 112 (132a, 132b).
    private var height: CGFloat {
        overview.rows.count + (overview.remainder == nil ? 0 : 1) > 3 ? 148 : 112
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            summary
                .frame(width: ModernTheme.leadingColumnWidth, height: height, alignment: .topLeading)
            VStack(spacing: 0) {
                ForEach(overview.rows, id: \.provider) { row in
                    ModernOverviewRow(row: row) { select(row.provider) }
                }
                if let remainder = overview.remainder {
                    ModernOverviewRemainder(remainder: remainder)
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModernBigNumber(
                value: "\(overview.attentionCount)",
                color: ModernTheme.toned(overview.tone),
                suffix: "/\(overview.total)"
            )
            Text("个订阅要留意")
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .frame(height: 18)
            Spacer(minLength: 0)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                count("快用完", overview.nearlyEmpty, tone: .red)
                count("偏快", overview.fast, tone: .amber)
            }
        }
    }

    private func count(_ label: String, _ value: Int, tone: QuotaPaceTone) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .frame(width: 36, alignment: .leading)
            Text("\(value)")
                .font(ModernTheme.mono(13, .medium))
                .foregroundStyle(value > 0 ? ModernTheme.toned(tone) : ModernTheme.secondaryText)
        }
        .frame(height: 18)
    }
}

/// One subscription on the overview: mark, name, the percentages of its ring
/// windows (plus the alerting allowance that has no bar, e.g. 「Fable 9%」),
/// the bar, and the comment at the right. Clicking it opens the subscription.
struct ModernOverviewRow: View {
    let row: QuotaSubscriptionDisplay
    let action: () -> Void
    @Environment(\.modernQuotaPreview) private var preview
    @State private var hoverState = false

    private var isHovered: Bool { hoverState || preview.hoveredOverviewRow == row.provider }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // Measured against 131a: the mixed faces sit 1.5 pt high
                    // in an 18 pt line.
                    nameLine.frame(height: 18).offset(y: 1.5)
                    lower.padding(.top, -1)
                }
                .frame(width: barWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            // The comment column is 50 pt; a slightly longer word (「已暂停读取」)
            // reaches into the 12 pt gap so every bar keeps the same length.
            .overlay(alignment: .topTrailing) { comment.padding(.top, 19) }
            .padding(.top, 3)
            .frame(height: 37, alignment: .top)
            .background(alignment: .top) {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ModernTheme.text.opacity(0.06))
                        .padding(.horizontal, -8)
                        .padding(.bottom, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverState = $0 }
        .accessibilityLabel("\(row.provider.displayName) \(row.comment ?? "")")
    }

    /// 242 pt, shorter only when a long state word (「未检测到安装」) would
    /// otherwise run into the bar.
    private var barWidth: CGFloat {
        guard let text = row.comment, !row.showsSkeleton, row.readState != .nonSubscriptionLogin else {
            return ModernOverviewBar.width
        }
        return min(ModernOverviewBar.width, 304 - ModernQuotaFormat.approximateWidth(text, size: 11) - 6)
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ProviderGlyph(provider: row.provider, size: 14)
                .foregroundStyle(ModernTheme.strongText)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                .padding(.trailing, 6)
            Text(row.provider.displayName)
                .font(ModernTheme.text(13, .medium))
                .foregroundStyle(ModernTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if row.showsSkeleton {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ModernTheme.placeholder)
                    .frame(width: 50, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            } else {
                meters
            }
        }
    }

    @ViewBuilder
    private var meters: some View {
        if let alert = row.additionalAlert, let remaining = alert.remaining {
            ModernMeterChip(label: alert.label, value: remaining, tone: alert.tone)
                .fixedSize()
                .padding(.trailing, 8)
        }
        if let inner = row.inner, let remaining = inner.remaining {
            ModernMeterChip(label: inner.label, value: remaining)
                .frame(width: 50, alignment: .trailing)
                .padding(.trailing, 8)
        }
        if let outer = row.outer, let remaining = outer.remaining {
            ModernMeterChip(label: outer.label, value: remaining)
                .frame(width: 50, alignment: .trailing)
        } else if row.inner == nil, let tightest = row.tightest, let remaining = tightest.remaining {
            // Only a feature allowance (no recognized period): its number,
            // without a bar.
            ModernMeterChip(label: tightest.label, value: remaining)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var lower: some View {
        if row.showsSkeleton {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ModernTheme.placeholder)
                .frame(height: 6)
                .padding(.top, 5)
                .frame(height: 11, alignment: .top)
        } else if row.readState == .nonSubscriptionLogin, let comment = row.comment {
            // 132e: the reason takes the bar's place; nothing at the right.
            Text(comment)
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .lineLimit(1)
                .frame(height: 14)
                .padding(.top, 2)
        } else {
            ModernOverviewBar(outer: ModernGaugeValue(row.outer), inner: ModernGaugeValue(row.inner))
        }
    }

    @ViewBuilder
    private var comment: some View {
        if !row.showsSkeleton, row.readState != .nonSubscriptionLogin, let text = row.comment {
            ModernCommentText(text: text)
                .foregroundStyle(ModernTheme.toned(row.commentTone, neutral: neutralCommentColor))
                .fixedSize()
                .frame(height: 14)
        }
    }

    /// 「需登录」 and 「登录已失效」 ask the user to act, so they sit a step
    /// brighter than the other short states (132e).
    private var neutralCommentColor: Color {
        switch row.readState {
        case .needsLogin, .loginExpired: ModernTheme.strongText
        default: ModernTheme.secondaryText
        }
    }
}

/// 「5h 12%」: label in 11, number in 13 medium, the percent sign dimmer
/// unless the number is colored.
struct ModernMeterChip: View {
    let label: String
    let value: Double
    var tone: QuotaPaceTone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(ModernTheme.mono(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .padding(.trailing, 4)
            Text(ModernQuotaFormat.percent(value))
                .font(ModernTheme.mono(13, .medium))
                .tracking(-0.26)
                .foregroundStyle(ModernTheme.toned(tone))
            Text("%")
                .font(ModernTheme.mono(13))
                .foregroundStyle(tone == .neutral ? ModernTheme.tertiaryText : ModernTheme.toned(tone))
        }
        .lineLimit(1)
    }
}

/// 「超额 17%」 with the number in the number face; other comments as they are.
struct ModernCommentText: View {
    let text: String

    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1].contains(where: \.isNumber) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts[0]).font(ModernTheme.text(11))
                Text(parts[1]).font(ModernTheme.mono(11))
            }
        } else {
            Text(text).font(ModernTheme.text(11))
        }
    }
}

/// 「其余 N 个」 (132c, 132d): the folded subscriptions' marks and their summary.
struct ModernOverviewRemainder: View {
    let remainder: QuotaOverviewDisplay.Remainder

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("其余 ")
                    Text("\(remainder.providers.count)").font(ModernTheme.mono(13, .medium))
                    Text(" 个")
                }
                .font(ModernTheme.text(13, .medium))
                .foregroundStyle(ModernTheme.secondaryText)
                .fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach(remainder.providers, id: \.self) { provider in
                        ProviderGlyph(provider: provider, size: 14)
                            .frame(width: 14, height: 14)
                            .help(provider.displayName)
                    }
                }
                .foregroundStyle(ModernTheme.tertiaryText)
            }
            .frame(maxWidth: ModernOverviewBar.width)
            Spacer(minLength: 12)
            Text(remainder.summary ?? "")
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.toned(remainder.tone, neutral: ModernTheme.secondaryText))
                .fixedSize()
                .frame(minWidth: 50, alignment: .trailing)
        }
        .frame(height: 37)
    }
}

// MARK: - One subscription (131b–131d, 132g, 132i–132r)

struct ModernQuotaDetail: View {
    let subscription: QuotaSubscriptionDisplay
    let retry: () -> Void
    let openCursorSignIn: () -> Void

    @Environment(\.modernQuotaPreview) private var preview
    @State private var expandedState = false
    @State private var hoveredState: String?

    private var isExpanded: Bool { expandedState || preview.expanded }
    private var hoveredRow: Binding<String?> {
        Binding(get: { hoveredState ?? preview.hoveredDetailRow }, set: { hoveredState = $0 })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ModernQuotaRing(
                outer: ModernGaugeValue(subscription.outer),
                inner: ModernGaugeValue(subscription.inner),
                isEmpty: subscription.outer == nil && subscription.inner == nil
            ) {
                ringCenter
            }
            .padding(.leading, -7)
            .frame(width: ModernTheme.leadingColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                header
                if subscription.rows.isEmpty {
                    message
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, minHeight: ModernQuotaRing<EmptyView>.size, alignment: .leading)
        }
    }

    // MARK: Ring center

    @ViewBuilder
    private var ringCenter: some View {
        if subscription.showsSkeleton {
            ModernRingSpinner()
        } else if let tightest = subscription.tightest, let remaining = tightest.remaining {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(ModernQuotaFormat.percent(remaining))
                        .font(ModernTheme.mono(44, .light))
                        .tracking(-2.64)
                        .foregroundStyle(ModernTheme.toned(tightest.tone))
                    Text("%")
                        .font(ModernTheme.mono(22, .light))
                        .foregroundStyle(ModernTheme.secondaryText)
                        .padding(.leading, 2)
                }
                .frame(height: 44)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(tightest.label).font(ModernTheme.mono(11))
                    Text("剩余").font(ModernTheme.text(11)).tracking(1.1)
                }
                .foregroundStyle(ModernTheme.secondaryText)
                .frame(height: 14)
            }
            // Optical center: the caption hangs under the number.
            .offset(y: 1)
        } else {
            Capsule()
                .fill(ModernTheme.text.opacity(0.3))
                .frame(width: 22, height: 2)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ProviderGlyph(provider: subscription.provider, size: 15)
                .foregroundStyle(ModernTheme.strongText)
                .frame(width: 15, height: 15)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                .padding(.trailing, 7)
            Text(subscription.provider.displayName)
                .font(ModernTheme.text(13, .semibold))
                .tracking(-0.13)
                .foregroundStyle(ModernTheme.text)
                .lineLimit(1)
            if let plan = subscription.planLabel {
                Text(plan)
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 7)
            }
            Spacer(minLength: 8)
            if let credits = subscription.resetCreditsCount, credits > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("重置券").font(ModernTheme.text(11))
                    Text("×\(credits)").font(ModernTheme.mono(11))
                }
                .foregroundStyle(ModernTheme.strongText)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(ModernTheme.text.opacity(0.08)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .frame(height: 22)
        // Measured against 131b, like the overview's name line.
        .offset(y: 1.5)
        .padding(.bottom, 10)
    }

    // MARK: Rows

    private var visibleRows: [QuotaPanelMeter] {
        isExpanded ? subscription.rows : subscription.compactRows
    }

    @ViewBuilder
    private var rows: some View {
        let shown = visibleRows
        let labelWidth = ModernQuotaFormat.labelColumnWidth(shown.map(\.label))
        ForEach(shown, id: \.id) { meter in
            ModernDetailRow(
                meter: meter,
                provider: subscription.provider,
                labelWidth: labelWidth,
                hoveredRow: hoveredRow
            )
        }
        if subscription.foldedCount > 0 {
            Button {
                expandedState.toggle()
                hoveredState = nil
            } label: {
                HStack(spacing: 6) {
                    if isExpanded {
                        Text("收起")
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("另有 ")
                            Text("\(subscription.foldedCount)").font(ModernTheme.mono(11))
                            Text(" 项")
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(ModernTheme.text(11))
                .padding(.top, 2)
                .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ModernTextButtonStyle(color: ModernTheme.secondaryText))
            .overlay(alignment: .top) { ModernRule() }
            .padding(.top, 1)
        }
        if let note = subscription.sourceNote {
            Text(note)
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
                .overlay(alignment: .top) { ModernRule() }
                .padding(.top, 1)
        }
    }

    // MARK: Nothing to draw (132m–132p)

    private var message: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine
            if let reason = subscription.detailReason {
                Text(reason)
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if subscription.action == .retry {
                Button(action: retry) {
                    Text("重试")
                        .font(ModernTheme.text(11, .medium))
                        .foregroundStyle(ModernTheme.text)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(Capsule().fill(ModernTheme.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
        .padding(.top, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { ModernRule() }
    }

    @ViewBuilder
    private var titleLine: some View {
        let title = Text(subscription.detailTitle ?? "")
            .font(ModernTheme.text(13, .medium))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        if subscription.action == .cursorSettings {
            // Cursor's own login cannot be read: the line leads to the
            // sign-in row in Settings.
            Button(action: openCursorSignIn) {
                HStack(spacing: 6) {
                    title
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.7)
                }
                .frame(minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(ModernTextButtonStyle(color: ModernTheme.text.opacity(0.92)))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if subscription.readState == .readFailed {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ModernTheme.red)
                }
                title.foregroundStyle(ModernTheme.toned(subscription.commentTone))
            }
            .frame(minHeight: 18)
        }
    }
}

/// One allowance in the detail: label, remaining, the forecast, the reset.
/// Hovering lights the row and publishes its tooltip to the panel root.
struct ModernDetailRow: View {
    let meter: QuotaPanelMeter
    let provider: ProviderRateLimit.Provider
    let labelWidth: CGFloat
    @Binding var hoveredRow: String?

    private var isHovered: Bool { hoveredRow == meter.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(meter.label)
                .font(ModernTheme.mono(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if let remaining = meter.remaining {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(ModernQuotaFormat.percent(remaining))
                        .font(ModernTheme.mono(13, .medium))
                        .tracking(-0.26)
                        .foregroundStyle(ModernTheme.text)
                    Text("%")
                        .font(ModernTheme.mono(13))
                        .foregroundStyle(ModernTheme.tertiaryText)
                }
                .frame(width: 52, alignment: .leading)
                Text(meter.prediction.map(ModernQuotaFormat.prediction) ?? "")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.toned(meter.tone, neutral: ModernTheme.secondaryText))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let reset = ModernQuotaFormat.reset(meter) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                        ModernMixedNumberText(text: reset, size: 11)
                    }
                    .foregroundStyle(ModernTheme.secondaryText)
                    .fixedSize()
                }
            } else {
                Text(meter.message ?? "")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 31)
        .frame(maxWidth: .infinity)
        .padding(.top, 1)
        .overlay(alignment: .top) { ModernRule() }
        .background {
            // The highlight reaches 8 pt past the row on both sides, and the
            // tooltip hangs from it.
            // (The anchor is taken on the shape itself: a negative padding
            // keeps reporting the row's own bounds.)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ModernTheme.text.opacity(isHovered ? 0.05 : 0))
                .anchorPreference(key: ModernQuotaTooltipKey.self, value: .bounds) { anchor in
                    guard isHovered, let tooltip = ModernQuotaFormat.tooltip(for: meter, provider: provider) else {
                        return nil
                    }
                    return ModernQuotaTooltipAnchor(tooltip: tooltip, anchor: anchor)
                }
                .padding(.horizontal, -8)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredRow = meter.id } else if hoveredRow == meter.id { hoveredRow = nil }
        }
    }
}

/// The 8% line between rows.
struct ModernRule: View {
    var body: some View {
        Rectangle()
            .fill(ModernTheme.text.opacity(0.08))
            .frame(height: 1)
    }
}

/// The ring's reading spinner (132m): a 22 pt faint circle with a bright
/// quarter, thinner than the small spinners.
struct ModernRingSpinner: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSince(start) / 0.9
            ZStack {
                Circle().stroke(ModernTheme.text.opacity(0.14), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(ModernTheme.text.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turns.truncatingRemainder(dividingBy: 1) * 360))
            }
            .padding(3.2)
        }
        .frame(width: 22, height: 22)
    }
}
