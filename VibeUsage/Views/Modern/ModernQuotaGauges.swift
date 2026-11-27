import SwiftUI

// Drawn parts of the 订阅配额 card (design 131–133): the overview bar, the
// double ring, the round button and the row tooltip. They only draw the
// numbers `QuotaPanelDisplay` hands them; no pace or color rule lives here.

extension ModernTheme {
    /// Warm white of ticks, rings and bars: `rgb(237,233,225)` (design §4).
    static let ink = Color(red: 237 / 255, green: 233 / 255, blue: 225 / 255)

    /// A quota tone as the color it is drawn in.
    static func accent(_ tone: QuotaPaceTone) -> Color? {
        switch tone {
        case .neutral: nil
        case .amber: amber
        case .red: red
        }
    }

    /// Text in a tone: the accent, else the given neutral.
    static func toned(_ tone: QuotaPaceTone, neutral: Color = text) -> Color {
        accent(tone) ?? neutral
    }

    /// Lit parts brighten along their length: ink from 45% to 90% (95% for
    /// solid lines), an accent from 62% to 100%.
    static func litColor(_ tone: QuotaPaceTone, at progress: Double, solid: Bool = false) -> Color {
        if let accent = accent(tone) {
            return accent.opacity(0.62 + 0.38 * progress)
        }
        return ink.opacity(0.45 + (solid ? 0.5 : 0.45) * progress)
    }
}

/// One meter as a gauge draws it: how much is left, where time says it should
/// be, and its tone. Built from a `QuotaPanelMeter`, never computed here.
struct ModernGaugeValue: Equatable {
    /// 0…1 left.
    let remaining: Double
    /// 0…1 the window's time says should be left; nil without timing.
    let expected: Double?
    let tone: QuotaPaceTone

    init?(_ meter: QuotaPanelMeter?) {
        guard let meter, let remaining = meter.remaining else { return nil }
        self.remaining = min(1, max(0, remaining / 100))
        expected = meter.expectedRemaining.map { min(1, max(0, $0 / 100)) }
        tone = meter.tone
    }
}

// MARK: - Overview bar (131a)

/// The bar under an overview row: ticks for the longer window, the thin line
/// under them for the shorter one, a small triangle (and a small mark on the
/// line) where time says each should be. Without a shorter window the line is
/// left out; without any window every tick is dim.
struct ModernOverviewBar: View {
    let outer: ModernGaugeValue?
    let inner: ModernGaugeValue?

    static let tickCount = 61
    static let width: CGFloat = 242

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let count = Self.tickCount
            let step = (width - 1.5) / CGFloat(count - 1)
            for index in 0..<count {
                let p = (Double(index) + 0.5) / Double(count)
                let color: Color
                if let outer, outer.remaining > 0, p <= outer.remaining {
                    color = ModernTheme.litColor(outer.tone, at: p / outer.remaining)
                } else {
                    color = ModernTheme.ink.opacity(0.13)
                }
                let rect = CGRect(x: CGFloat(index) * step, y: 5, width: 1.5, height: 6)
                context.fill(Path(rect), with: .color(color))
            }
            if let expected = outer?.expected {
                let x = CGFloat(expected) * width
                var triangle = Path()
                triangle.move(to: CGPoint(x: x - 2.5, y: 0))
                triangle.addLine(to: CGPoint(x: x + 2.5, y: 0))
                triangle.addLine(to: CGPoint(x: x, y: 4))
                triangle.closeSubpath()
                context.fill(triangle, with: .color(ModernTheme.text.opacity(0.7)))
            }
            guard let inner else { return }
            let track = Path(roundedRect: CGRect(x: 0, y: 13, width: width, height: 2.5), cornerRadius: 1.25)
            context.fill(track, with: .color(ModernTheme.ink.opacity(0.11)))
            let litWidth = CGFloat(inner.remaining) * width
            if litWidth > 0 {
                let lit = Path(roundedRect: CGRect(x: 0, y: 13, width: litWidth, height: 2.5), cornerRadius: 1.25)
                context.fill(lit, with: .linearGradient(
                    Gradient(colors: [ModernTheme.litColor(inner.tone, at: 0, solid: true),
                                      ModernTheme.litColor(inner.tone, at: 1, solid: true)]),
                    startPoint: .zero, endPoint: CGPoint(x: max(litWidth, 1), y: 0)
                ))
            }
            if let expected = inner.expected {
                let mark = CGRect(x: CGFloat(expected) * width - 0.75, y: 12, width: 1.5, height: 5)
                context.fill(Path(mark), with: .color(ModernTheme.text.opacity(0.7)))
            }
        }
        .frame(height: inner == nil ? 11 : 17)
        .accessibilityHidden(true)
    }
}

// MARK: - Double ring (131b–131d, 132m–132p)

/// The 148 pt ring of one subscription: 96 ticks for the longer window, a
/// solid inner arc for the shorter one, a triangle outside the ticks and a
/// small mark inside the arc where time says each should be. With one window
/// only the ticks are drawn; with none the ticks are dim, the arc is an empty
/// track and the center holds a spinner (reading) or a dash.
struct ModernQuotaRing<Center: View>: View {
    let outer: ModernGaugeValue?
    let inner: ModernGaugeValue?
    /// No window to draw at all (reading, read failed, …): the empty track.
    var isEmpty = false
    @ViewBuilder var center: Center

    /// The card body's height, which 近期消耗 shares.
    static var size: CGFloat { ModernTheme.cardBodyHeight }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                drawTicks(in: &context, center: c)
                if let inner {
                    drawArc(inner, in: &context, center: c)
                } else if isEmpty {
                    var track = Path()
                    track.addArc(center: c, radius: 56, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                    context.stroke(track, with: .color(ModernTheme.ink.opacity(0.09)), lineWidth: 6)
                }
            }
            center
        }
        .frame(width: Self.size, height: Self.size)
    }

    private func drawTicks(in context: inout GraphicsContext, center c: CGPoint) {
        let count = 96
        for index in 0..<count {
            let p = (Double(index) + 0.5) / Double(count)
            let color: Color
            if let outer, outer.remaining > 0, p <= outer.remaining {
                color = ModernTheme.litColor(outer.tone, at: p / outer.remaining)
            } else {
                color = ModernTheme.ink.opacity(0.13)
            }
            // A 1.5 × 6 tick from 61 to 67 pt off center, turned to its angle.
            let tick = Path(CGRect(x: -0.75, y: -67, width: 1.5, height: 6))
                .applying(CGAffineTransform(rotationAngle: p * 2 * .pi))
                .applying(CGAffineTransform(translationX: c.x, y: c.y))
            context.fill(tick, with: .color(color))
        }
        if let expected = outer?.expected {
            var triangle = Path()
            triangle.move(to: CGPoint(x: -2.5, y: -74))
            triangle.addLine(to: CGPoint(x: 2.5, y: -74))
            triangle.addLine(to: CGPoint(x: 0, y: -70))
            triangle.closeSubpath()
            let placed = triangle
                .applying(CGAffineTransform(rotationAngle: expected * 2 * .pi))
                .applying(CGAffineTransform(translationX: c.x, y: c.y))
            context.fill(placed, with: .color(ModernTheme.text.opacity(0.7)))
        }
    }

    private func drawArc(_ inner: ModernGaugeValue, in context: inout GraphicsContext, center c: CGPoint) {
        var track = Path()
        track.addArc(center: c, radius: 56, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        context.stroke(track, with: .color(ModernTheme.ink.opacity(0.09)), lineWidth: 6)
        if inner.remaining > 0 {
            let sweep = inner.remaining * 360
            var arc = Path()
            arc.addArc(center: c, radius: 56, startAngle: .degrees(-90), endAngle: .degrees(-90 + sweep), clockwise: false)
            let start = inner.tone == .neutral ? ModernTheme.ink.opacity(0.45) : ModernTheme.litColor(inner.tone, at: 0)
            let end = inner.tone == .neutral ? ModernTheme.ink.opacity(0.95) : ModernTheme.litColor(inner.tone, at: 0.87)
            context.stroke(arc, with: .conicGradient(
                Gradient(stops: [.init(color: start, location: 0), .init(color: end, location: inner.remaining)]),
                center: c, angle: .degrees(-90)
            ), lineWidth: 6)
        }
        if let expected = inner.expected {
            let mark = Path(CGRect(x: -0.75, y: -51, width: 1.5, height: 6))
                .applying(CGAffineTransform(rotationAngle: expected * 2 * .pi))
                .applying(CGAffineTransform(translationX: c.x, y: c.y))
            context.fill(mark, with: .color(ModernTheme.text.opacity(0.7)))
        }
    }
}

// MARK: - Round button (133)

/// The 30 pt round button of one subscription: a dark well, the remaining
/// arc of its tightest allowance around it, a raised face with the product's
/// mark, lit when selected. A white dot at the top right marks a subscription
/// whose read needs attention. An allowance that is used up leaves only a red
/// start point.
struct ModernRoundButtonFace: View {
    let provider: ProviderRateLimit.Provider
    /// 0…100 of the tightest allowance; nil draws no arc.
    let remaining: Double?
    let isSelected: Bool
    let showsDot: Bool
    var isHovered = false

    static let size: CGFloat = 30

    var body: some View {
        ZStack {
            well
            arc
            face
            ModernButtonGlyph(provider: provider)
                .foregroundStyle(glyphColor)
                .shadow(color: .black.opacity(isSelected ? 0.4 : 0), radius: 0, x: 0, y: 0.5)
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(alignment: .topLeading) {
            if showsDot {
                ZStack {
                    Circle().fill(Color(settingsHex: 0x1D2025)).frame(width: 9, height: 9)
                    Circle().fill(Color(settingsHex: 0xD8D5CF)).frame(width: 5, height: 5)
                }
                .offset(x: 26 - 4.5, y: 4 - 4.5)
            }
        }
    }

    private var glyphColor: Color {
        if isSelected { return .white }
        // A subscription with nothing to show and a problem to look at dims
        // its mark (132e); hovering brings it up like other icon buttons.
        return showsDot && remaining == nil && !isHovered ? Color(settingsHex: 0x5E6369) : ModernButtonGlyph.restingColor
    }

    private var well: some View {
        Circle()
            .fill(Color(settingsHex: 0x121518))
            .overlay(
                Circle().fill(RadialGradient(
                    stops: [.init(color: .clear, location: 0.78), .init(color: .black.opacity(0.7), location: 1)],
                    center: UnitPoint(x: 0.5, y: 34.0 / 60), startRadius: 0, endRadius: 15
                ))
            )
            .overlay(
                Circle().inset(by: 0.25).stroke(LinearGradient(
                    stops: [.init(color: .white.opacity(0), location: 0.55), .init(color: .white.opacity(0.1), location: 1)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var arc: some View {
        let radius: CGFloat = 13.25
        if let remaining {
            let fraction = min(1, max(0, remaining / 100))
            if fraction > 0 {
                let end = isSelected ? ModernTheme.ink : ModernTheme.ink.opacity(0.58)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AngularGradient(
                        stops: [.init(color: ModernTheme.ink.opacity(0.2), location: 0),
                                .init(color: end, location: fraction)],
                        center: .center
                    ), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                if isSelected {
                    // The bright end glows a little (`r 3.6, blur 2.2, .55`).
                    let angle = fraction * 2 * .pi
                    Circle()
                        .fill(ModernTheme.ink.opacity(0.55))
                        .frame(width: 3.6, height: 3.6)
                        .blur(radius: 1.1)
                        .offset(x: radius * sin(angle), y: -radius * cos(angle))
                }
            } else {
                Circle()
                    .fill(ModernTheme.red)
                    .frame(width: 2, height: 2)
                    .offset(y: -radius)
            }
        }
    }

    private var face: some View {
        // Unselected faces sit a step darker than the design's `#2E3339 →
        // #212529`, so the full-brightness marks stand out (maintainer
        // 2026-11-27, variant D); the pointer lifts the face a little.
        let colors: [Color] = isSelected
            ? [Color(settingsHex: 0x7C858E), Color(settingsHex: 0x4F565E)]
            : (isHovered ? [Color(settingsHex: 0x31363C), Color(settingsHex: 0x25292D)]
                         : [Color(settingsHex: 0x272B30), Color(settingsHex: 0x1C1F23)])
        let top = isSelected ? 0.34 : 0.12
        let bottom = isSelected ? 0.3 : 0.35
        return Circle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Circle().inset(by: 0.25).stroke(LinearGradient(
                    stops: [.init(color: .white.opacity(top), location: 0),
                            .init(color: .white.opacity(0), location: 0.4),
                            .init(color: .black.opacity(0), location: 0.62),
                            .init(color: .black.opacity(bottom), location: 1)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 0.5)
            )
            .frame(width: 21, height: 21)
            .background(
                Circle().fill(.black.opacity(0.7)).frame(width: 20.5, height: 20.5)
                    .blur(radius: 0.85).offset(y: 1.2)
            )
    }
}

/// A provider's mark inside a round button. The real marks are finer than
/// the design's stand-in symbols (thin strands, many points), so they are
/// drawn in the full text color on a darker face (maintainer 2026-11-27,
/// variant D; the design's `#8B9096` read grey), each in a box sized to its
/// own visual weight so the row looks even, and placed on whole points
/// (crisp straight edges at 2×). The classic panel and Settings keep
/// `ProviderGlyph` unchanged.
struct ModernButtonGlyph: View {
    let provider: ProviderRateLimit.Provider

    static let restingColor = ModernTheme.text

    var body: some View {
        let side = Self.side(for: provider)
        ProviderGlyphShape(provider: provider)
            .fill(style: FillStyle(eoFill: true))
            .frame(width: side, height: side)
    }

    /// Side of the box the 24-unit mark is drawn in, in whole points: fine
    /// strands get more room, solid shapes less. Each mark's farthest point
    /// stays at least 0.8 pt inside the 21 pt face (Grok's slash reaches its
    /// corners, so it stops at 14).
    static func side(for provider: ProviderRateLimit.Provider) -> CGFloat {
        switch provider {
        case .claudeCode: 15
        case .grok, .codex, .kimiCode: 14
        case .cursor, .antigravity, .opencodeGo: 13
        case .zCode: 12
        }
    }
}

// MARK: - Row tooltip (132r)

/// What hovering an allowance row shows: its window, then 已使用 / 已过去 /
/// 离重置 (and the allowance's own split, when the source gave one).
struct ModernQuotaTooltip: Equatable {
    struct Line: Equatable {
        let label: String
        let value: String
    }

    let id: String
    let title: String
    let lines: [Line]
}

struct ModernQuotaTooltipAnchor {
    let tooltip: ModernQuotaTooltip
    let anchor: Anchor<CGRect>
}

/// Published by the hovered row and drawn by the panel root, above every card
/// and scroller (the classic panel's `QuotaTooltipPreferenceKey` pattern).
struct ModernQuotaTooltipKey: PreferenceKey {
    static var defaultValue: ModernQuotaTooltipAnchor? { nil }

    static func reduce(value: inout ModernQuotaTooltipAnchor?, nextValue: () -> ModernQuotaTooltipAnchor?) {
        value = value ?? nextValue()
    }
}

/// The panel-wide layer that draws the hovered row's tooltip.
struct ModernQuotaTooltipOverlay: View {
    let value: ModernQuotaTooltipAnchor?

    var body: some View {
        GeometryReader { proxy in
            if let value {
                ModernTooltipLayout(rowRect: proxy[value.anchor], container: proxy.size) {
                    ModernQuotaTooltipView(tooltip: value.tooltip)
                }
            }
        }
        // Decorative: the pointer keeps driving the rows underneath.
        .allowsHitTesting(false)
    }
}

/// Hangs the tooltip 2 pt under the row's highlight, right edges aligned
/// (132r); above the row when the panel's bottom is too close.
private struct ModernTooltipLayout: Layout {
    let rowRect: CGRect
    let container: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        container
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let inset: CGFloat = 8
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let x = min(max(inset, rowRect.maxX - size.width), max(inset, bounds.width - size.width - inset))
            let below = rowRect.maxY + 2
            let above = rowRect.minY - 2 - size.height
            let y = below + size.height + inset <= bounds.height ? below : max(inset, above)
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
    }
}

private struct ModernQuotaTooltipView: View {
    let tooltip: ModernQuotaTooltip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tooltip.title)
                .font(ModernTheme.text(11, .medium))
                .foregroundStyle(ModernTheme.text)
                .frame(height: 16)
            VStack(spacing: 0) {
                ForEach(Array(tooltip.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(line.label)
                            .foregroundStyle(ModernTheme.secondaryText)
                            .truncationMode(.middle)
                        Spacer(minLength: 14)
                        ModernMixedNumberText(text: line.value, size: 11)
                            .foregroundStyle(ModernTheme.text)
                            .fixedSize()
                    }
                    .frame(height: 16)
                }
            }
            .font(ModernTheme.text(11))
            .padding(.top, 2)
        }
        .lineLimit(1)
        .frame(width: 156, alignment: .leading)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(settingsHex: 0x2A2E34), Color(settingsHex: 0x22262B)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        .mask(alignment: .top) {
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8)
                        }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
        )
    }
}

/// A short phrase whose digits are set in the number face and the rest in the
/// text face, e.g. 「3 天 17 小时」 or 「21%」.
struct ModernMixedNumberText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                Text(run.text).font(run.isNumber ? ModernTheme.mono(size) : ModernTheme.text(size))
            }
        }
    }

    private var runs: [(text: String, isNumber: Bool)] {
        var result: [(String, Bool)] = []
        for character in text {
            let isNumber = character.isNumber || character == "%" || character == "." || character == "<"
                || character == ":" || character == "/" || character == "×"
            if let last = result.last, last.1 == isNumber {
                result[result.count - 1].0.append(character)
            } else {
                result.append((String(character), isNumber))
            }
        }
        return result
    }
}
