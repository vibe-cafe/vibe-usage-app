import SwiftUI
import UniformTypeIdentifiers

/// 订阅配额: one table of every product — monochrome mark and name, local
/// status, the panel-card switch, a drag handle at the row's end. Enabled
/// products come first; the rest sit under 「未开启」. Both the order and the
/// switches are the panel's own (`quotaProductOrder`, `selectedQuotaProductIds`):
/// dragging here reorders the panel's tabs too, and turning a product on moves
/// its row into the top group.
///
/// A product that needs more than a switch (ZCode's key) has a disclosure
/// triangle at the row's start and opens into a rounded block under its row.
struct SettingsQuotaPage: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(\.settingsTheme) private var theme
    @State private var drag = QuotaDragState()

    private var enabled: [ProviderRateLimit.Provider] {
        appState.quotaTabOrder.filter { appState.isQuotaProviderSelected($0) }
    }

    private var disabled: [ProviderRateLimit.Provider] {
        appState.quotaTabOrder.filter { !appState.isQuotaProviderSelected($0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPageScroll(bottomInset: 8) {
                SettingsPageHeader(title: SettingsPage.quotas.title) {
                    SettingsNumberText.text(
                        "\(enabled.count) / \(appState.quotaProducts.count) 已开启 · 拖动排序",
                        font: theme.isModern ? theme.caption : theme.body,
                        numberFont: theme.numberFont?(.regular)
                    )
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                } trailing: {
                    Button {
                        appState.rediscoverQuotaProducts()
                    } label: {
                        SettingsIconLabel(title: "重新检测", systemImage: "arrow.2.circlepath")
                    }
                    .buttonStyle(.settings)
                    .help("重新检测本机产品")
                }
                table
                SettingsSection(title: "隐私保护") {
                    EgressSettingsRow()
                }
            }
            .onAppear { reveal(navigation.focusedProvider, proxy: proxy) }
            // Whether the CLI the app runs has `login cursor` (the Cursor
            // row's sign-in appears once it does).
            .task { await appState.cursorLogin.checkCLISupport() }
            .onChange(of: navigation.focusRequest) { _, _ in
                reveal(navigation.focusedProvider, proxy: proxy)
            }
        }
    }

    private func reveal(_ provider: ProviderRateLimit.Provider?, proxy: ScrollViewProxy) {
        guard let provider else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(provider, anchor: .center) }
        }
    }

    // MARK: - Table

    /// Classic: 「未开启」 is a grey band. Modern: a small line of text under a
    /// rule, like the panel.
    private var table: some View {
        SettingsCard(padding: theme.isModern ? EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16) : nil) {
            QuotaTableHeader()
            rows(enabled)
            if !disabled.isEmpty {
                Text("未开启")
                    .font(theme.caption)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, theme.isModern ? 0 : 14)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background { Rectangle().fill(theme.band) }
                    .overlay(alignment: .top) {
                        if theme.isModern { theme.line.frame(height: 1) }
                    }
                rows(disabled)
            }
        }
        // Classic clips the band to the card's corners; modern must not clip
        // the card's shadow or a flashed row's wash, so there the clip is
        // pushed 24 pt out (same view either way, so switching keeps state).
        .padding(theme.isModern ? 24 : 0)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(theme.isModern ? -24 : 0)
    }

    private func rows(_ group: [ProviderRateLimit.Provider]) -> some View {
        ForEach(Array(group.enumerated()), id: \.element) { index, provider in
            if index > 0 { SettingsSeparator() }
            QuotaProductRow(
                provider: provider,
                drag: drag,
                enabled: enabled,
                disabled: disabled
            )
            .id(provider)
        }
    }
}

// MARK: - Header

/// The egress check's one setting (`EgressCheck.Mode`): what Codex, Claude,
/// Grok and Antigravity do when no proxy is detected. Classic: a system
/// pop-up button like System Settings' 「显示滚动条」. Modern: the panel's menu
/// (design §10 #15). What each option does is in the README, not here
/// (maintainer, 2026-11-26: no explanatory sentences in Settings).
private struct EgressSettingsRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let selection = Binding(
            get: { appState.egressMode },
            set: { appState.egressMode = $0 }
        )
        SettingsRow {
            SettingsRowLabel(title: "没检测到代理时")
            Spacer(minLength: 8)
            if theme.isModern {
                SettingsMenuPicker(
                    id: "egressMode", label: "没检测到代理时",
                    options: EgressCheck.Mode.allCases.map { ($0, $0.title) },
                    selection: selection
                )
            } else {
                Picker("没检测到代理时", selection: selection) {
                    ForEach(EgressCheck.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// 工具 · 状态 · 面板卡片, aligned with the row columns.
private struct QuotaTableHeader: View {
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text("工具")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("状态")
                .frame(width: QuotaProductRow.statusWidth(theme), alignment: .leading)
            Text("面板卡片")
                .fixedSize()
                .frame(width: 30, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }
        .font(theme.caption)
        .foregroundStyle(theme.secondaryText)
        .padding(.leading, QuotaProductRow.nameInset(theme))
        .padding(.trailing, theme.isModern ? 0 : 12)
        .frame(height: 28)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}

// MARK: - Drag state

/// What is being dragged and where its drop line is. Lives on the page so
/// every row's drop target sees the same drag.
@MainActor
@Observable
final class QuotaDragState {
    var dragged: ProviderRateLimit.Provider?
    var indicator: (provider: ProviderRateLimit.Provider, after: Bool)?
    @ObservationIgnored private var endMonitor: Any?

    /// A row started dragging. A successful drop clears the state in
    /// `performDrop`; a cancelled drag is noticed through the first click or
    /// key press after it (AppKit's drag loop keeps those events to itself
    /// until the drag is over), so a later drop never reuses this product.
    func begin(_ provider: ProviderRateLimit.Provider) {
        dragged = provider
        indicator = nil
        guard endMonitor == nil else { return }
        endMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.end() }
            return event
        }
    }

    func end() {
        dragged = nil
        indicator = nil
        if let endMonitor { NSEvent.removeMonitor(endMonitor) }
        endMonitor = nil
    }
}

// MARK: - Row

struct QuotaProductRow: View {
    /// Column metrics shared with the header. Classic: 状态 124 wide; names
    /// start 58 pt in, after the disclosure slot and the 22 pt mark; 40 pt
    /// rows. Modern: 状态 96 wide; names 36 pt in (a 14 pt disclosure slot and
    /// the 22 pt mark slot, no gap); 36 pt rows under a 1 pt rule slot.
    static func statusWidth(_ theme: SettingsTheme) -> CGFloat { theme.isModern ? 96 : 124 }
    static func nameInset(_ theme: SettingsTheme) -> CGFloat { theme.isModern ? 36 : 58 }
    static func rowHeight(_ theme: SettingsTheme) -> CGFloat { theme.isModern ? 37 : 40 }
    /// Where a disclosure's expanded content starts (modern: under the name).
    static func expansionLeading(_ theme: SettingsTheme) -> CGFloat { theme.isModern ? 36 : 14 }

    let provider: ProviderRateLimit.Provider
    let drag: QuotaDragState
    let enabled: [ProviderRateLimit.Provider]
    let disabled: [ProviderRateLimit.Provider]

    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(\.settingsTheme) private var theme
    @State private var flash = false

    private var isOn: Bool { appState.isQuotaProviderSelected(provider) }
    /// ZCode's key; Cursor's sign-in once the CLI has it (`CursorLogin`).
    private var isConfigurable: Bool {
        provider == .zCode || provider == .cursor && appState.cursorLogin.isAvailable
    }
    private var isExpanded: Bool { navigation.expandedProviders.contains(provider) }

    private var product: QuotaProduct {
        appState.quotaProducts.first { $0.provider == provider }
            ?? QuotaProduct(provider: provider, availability: .ready, isDetected: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            row
                .onDrop(of: [.plainText], delegate: QuotaRowDropDelegate(
                    row: provider,
                    drag: drag,
                    enabled: enabled,
                    disabled: disabled,
                    rowHeight: Self.rowHeight(theme),
                    move: { appState.moveQuotaProduct($0, before: $1) }
                ))
            if isConfigurable, isExpanded {
                // Classic: a rounded block under the row. Modern: the row's
                // second line, starting under the name (no box).
                Group {
                    if provider == .cursor {
                        CursorLoginBlock()
                    } else {
                        ZCodeConfigBlock()
                    }
                }
                .padding(.leading, Self.expansionLeading(theme))
                .padding(.trailing, theme.isModern ? 0 : 12)
                .padding(.bottom, theme.isModern ? 10 : 12)
            }
        }
        .onAppear { if navigation.focusedProvider == provider { pulse() } }
        .onChange(of: navigation.focusRequest) { _, _ in
            if navigation.focusedProvider == provider { pulse() }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: theme.isModern ? 0 : 10) {
                    QuotaRowMark(provider: provider, isOn: isOn)
                    Text(provider.displayName)
                        .font(theme.label)
                        .foregroundStyle(isOn ? theme.text : theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                QuotaStatusCell(value: statusValue, isOn: isOn)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isConfigurable { toggleExpanded() } }

            Toggle(provider.displayName, isOn: Binding(
                get: { isOn },
                set: { newValue in
                    Task { await appState.setQuotaProductSelected(provider, selected: newValue) }
                }
            ))
            .toggleStyle(.settingsSwitch)
            .disabled(!isOn && !appState.canSelectQuotaProvider(provider))

            DragHandle(dimmed: !isOn)
        }
        .padding(.leading, theme.isModern ? 14 : 26)
        .padding(.trailing, theme.isModern ? 0 : 12)
        .frame(height: theme.isModern ? 36 : Self.rowHeight(theme))
        .overlay(alignment: .leading) {
            if isConfigurable {
                Button(action: toggleExpanded) {
                    DisclosureTriangle(isOpen: isExpanded)
                        .frame(width: 12, height: 12)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The arrow's left edge on the rows' rule (classic 14, modern 0).
                .offset(x: theme.isModern ? -4 : 6)
                .help(isExpanded ? "收起" : "展开")
                .accessibilityLabel(isExpanded ? "收起 \(provider.displayName)" : "展开 \(provider.displayName)")
            }
        }
        .background {
            // The flash after arriving from the panel. Modern: the panel's
            // row wash, reaching 8 pt into the card's padding.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.selection)
                .padding(.horizontal, theme.isModern ? -8 : 4)
                .opacity(flash ? 1 : 0)
        }
        .padding(.top, theme.isModern ? 1 : 0)
        .overlay(alignment: indicatorEdge ?? .top) {
            if indicatorEdge != nil {
                theme.dropLine
                    .frame(height: 2)
                    .clipShape(Capsule())
                    // 10 pt from the card's edges.
                    .padding(.horizontal, theme.isModern ? -6 : 10)
                    .offset(y: indicatorEdge == .top ? -1 : 1)
            }
        }
        .contentShape(Rectangle())
        .onDrag {
            drag.begin(provider)
            return NSItemProvider(object: provider.rawValue as NSString)
        } preview: {
            // A drag preview is rendered outside this view's environment.
            QuotaDragPreview(provider: provider, isOn: isOn, status: statusValue, theme: theme)
        }
    }

    private var indicatorEdge: Alignment? {
        guard let indicator = drag.indicator, indicator.provider == provider else { return nil }
        return indicator.after ? .bottom : .top
    }

    private var statusValue: (kind: SettingsStatusKind, text: String) {
        SettingsQuotaStatus.status(
            for: product,
            zCodeKeyConfigured: appState.zCodeAPIKeyConfigured,
            warningSnapshot: appState.quotaWarningSnapshot(for: provider),
            cursorSignInEnded: provider == .cursor && appState.cursorLogin.phase.isExpired
        )
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if isExpanded {
                navigation.expandedProviders.remove(provider)
            } else {
                navigation.expandedProviders.insert(provider)
            }
        }
    }

    private func pulse() {
        flash = true
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { flash = false }
    }
}

/// The product's mark in its 22 pt slot. Classic: 18 pt, dimmed when off.
/// Modern: 15 pt, 86 % ink when on, 45 % when off.
private struct QuotaRowMark: View {
    let provider: ProviderRateLimit.Provider
    let isOn: Bool
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        if theme.isModern {
            ProviderGlyph(provider: provider, size: 15)
                .foregroundStyle(theme.text.opacity(isOn ? 0.86 : 0.45))
                .frame(width: 22, height: 22, alignment: .leading)
        } else {
            ProviderGlyph(provider: provider, size: 18)
                .foregroundStyle(isOn ? theme.text : theme.secondaryText)
                .opacity(isOn ? 1 : 0.72)
                .frame(width: 22, height: 22)
        }
    }
}

/// Six dots, always visible: the row can be dragged anywhere, the handle says so.
private struct DragHandle: View {
    let dimmed: Bool
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let color = theme.isModern ? theme.text.opacity(0.5) : theme.tertiaryText
        Canvas { context, _ in
            for x in [2.6, 7.4] {
                for y in [3.0, 8.0, 13.0] {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: 10, height: 16)
        .opacity(dimmed ? (theme.isModern ? 0.4 : 0.38) : (theme.isModern ? 0.8 : 0.75))
        .onHover { inside in
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .help("拖动排序")
        .accessibilityHidden(true)
    }
}

/// The row-start triangle: right when closed, down when open. Same shape and
/// weight in both styles (the maintainer kept it, design §10 「没动的」).
struct DisclosureTriangle: View {
    let isOpen: Bool
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 4.3, y: 2.3))
            path.addLine(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 4.3, y: 9.7))
        }
        .stroke(theme.secondaryText, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}

/// Classic: 13 pt, the text color while on. Modern: 11 pt in the secondary
/// color — only a problem is colored.
private struct QuotaStatusCell: View {
    let value: (kind: SettingsStatusKind, text: String)
    let isOn: Bool
    @Environment(\.settingsTheme) private var theme

    private var textColor: Color {
        switch value.kind {
        case .warning: theme.amber
        case .error: theme.red
        case .ok, .none: isOn && !theme.isModern ? theme.text : theme.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            SettingsStatusDot(kind: value.kind, dimmed: !isOn)
            Text(value.text)
                .font(theme.status)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .frame(width: QuotaProductRow.statusWidth(theme), alignment: .leading)
    }
}

/// What follows the pointer while a row is dragged: the row, lifted.
/// Classic: a raised grey row with a hairline. Modern: the panel's lifted
/// card — a lighter gradient, a deep soft shadow, a dark outline.
struct QuotaDragPreview: View {
    let provider: ProviderRateLimit.Provider
    let isOn: Bool
    let status: (kind: SettingsStatusKind, text: String)
    let theme: SettingsTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 10) {
            HStack(spacing: theme.isModern ? 0 : 10) {
                if theme.isModern {
                    ProviderGlyph(provider: provider, size: 15)
                        .foregroundStyle(theme.ok)
                        .frame(width: 22, height: 22, alignment: .leading)
                } else {
                    ProviderGlyph(provider: provider, size: 18)
                        .foregroundStyle(theme.text)
                        .frame(width: 22, height: 22)
                }
                Text(provider.displayName)
                    .font(theme.label)
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            QuotaStatusCell(value: status, isOn: isOn)
            SettingsSwitchTrack(isOn: isOn)
        }
        .padding(.leading, theme.isModern ? 16 : 20)
        .padding(.trailing, theme.isModern ? 14 : 18)
        .frame(width: theme.isModern ? 420 : 440, height: theme.isModern ? 36 : 40)
        .background {
            if theme.isModern {
                shape.fill(LinearGradient(
                    colors: [theme.raised, Color(settingsHex: 0x22262B)], startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        .mask(LinearGradient(
                            stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.1)],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
            } else {
                shape.fill(theme.raised)
            }
        }
        .overlay {
            if theme.isModern {
                shape.inset(by: -1).strokeBorder(Color.black.opacity(0.45), lineWidth: 1)
            } else {
                shape.strokeBorder(theme.strongLine, lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.settingsTheme, theme)
    }
}

// MARK: - Drop

private struct QuotaRowDropDelegate: DropDelegate {
    let row: ProviderRateLimit.Provider
    let drag: QuotaDragState
    let enabled: [ProviderRateLimit.Provider]
    let disabled: [ProviderRateLimit.Provider]
    let rowHeight: CGFloat
    let move: @MainActor (ProviderRateLimit.Provider, ProviderRateLimit.Provider?) -> Void

    private func target(_ info: DropInfo) -> QuotaReorder.Target {
        QuotaReorder.target(
            dragged: drag.dragged,
            row: row,
            dropAfter: info.location.y > rowHeight / 2,
            enabled: enabled,
            disabled: disabled
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        target(info) != .reject
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard target(info) != .reject else {
            if drag.indicator?.provider == row { drag.indicator = nil }
            return DropProposal(operation: .forbidden)
        }
        let after = info.location.y > rowHeight / 2
        if drag.indicator?.provider != row || drag.indicator?.after != after {
            drag.indicator = (row, after)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Only the line: the drag may just be moving on to the next row.
        if drag.indicator?.provider == row { drag.indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = target(info)
        let dragged = drag.dragged
        drag.end()
        guard case .before(let destination) = target, let dragged,
              let item = info.itemProviders(for: [.plainText]).first
        else { return false }
        // Move only when the dropped text is the row that started the drag:
        // plain text dragged in from elsewhere never reorders anything.
        let expected = dragged.rawValue
        let move = self.move
        item.loadObject(ofClass: NSString.self) { object, _ in
            guard (object as? NSString) as String? == expected else { return }
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.18)) { move(dragged, destination) }
            }
        }
        return true
    }
}

// MARK: - ZCode block

/// ZCode's key, on one line inside a rounded block a step lighter than the
/// card (maintainer, 2026-11-20: 「ZCode不要弄两行了，一行不行吗」): region
/// segments, the key field (or 「✓ Key 已保存」), then the action buttons.
/// Save never turns the switch on; remove turns it off.
struct ZCodeConfigBlock: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var model
    @Environment(\.settingsTheme) private var theme
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: theme.isModern ? 6 : 5) {
            GridRow {
                SettingsSegmented(
                    options: ZCodeQuotaRegion.allCases.map { ($0, $0.displayName) },
                    selection: Binding(
                        get: { appState.zCodeQuotaRegion },
                        set: { model.setZCodeRegion($0) }
                    )
                )
                .disabled(model.isSavingZCodeAPIKey)

                if model.showsSavedZCodeKey {
                    HStack(spacing: 6) {
                        SettingsCheckMark()
                        Text("Key 已保存")
                            .font(theme.body)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("更换") {
                            model.beginReplacingZCodeAPIKey()
                            fieldFocused = true
                        }
                        .buttonStyle(.settings)
                        Button("移除") { model.removeZCodeAPIKey() }
                            .buttonStyle(.settingsDanger)
                    }
                    .disabled(model.isSavingZCodeAPIKey)
                } else {
                    SettingsTextField(
                        prompt: "粘贴 API Key",
                        text: $model.zCodeAPIKeyDraft,
                        secure: true,
                        focus: $fieldFocused
                    )
                    .frame(maxWidth: .infinity)
                    .onSubmit { save() }
                    .onExitCommand {
                        if model.isReplacingZCodeAPIKey { model.cancelReplacingZCodeAPIKey() }
                    }
                    .help(appState.zCodeQuotaRegion.apiKeyName)

                    Button("保存", action: save)
                        .buttonStyle(.settings)
                        .disabled(!model.canSaveZCodeAPIKey)
                }
            }
            if let error = model.zCodeAPIKeyError {
                // Classic: under the field. Modern: from the line's start.
                GridRow {
                    if !theme.isModern { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    Text(error)
                        .font(theme.caption)
                        .foregroundStyle(theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(theme.isModern ? 3 : 2)
                }
            }
        }
        .padding(theme.isModern ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.configBlock)
            }
        }
        .onAppear {
            if model.isReplacingZCodeAPIKey { fieldFocused = true }
        }
    }

    private func save() {
        guard model.canSaveZCodeAPIKey else { return }
        Task { await model.saveZCodeAPIKey() }
    }
}

// MARK: - Cursor block

/// Cursor's own sign-in for Vibe Usage, on one line inside the same rounded
/// block as ZCode's key: where it stands on the left, one button on the
/// right. Four states (plan 《Cursor-加密凭据-方案》
/// §3): 未登录 → 登录; waiting for the browser → 取消; signed in (the
/// account's email) → 退出; ended or lapsed → 退出 / 重新登录. How to revoke it on
/// cursor.com is in the README, not in the app. The copy is
/// word for word the Windows app's (workspace notes
/// 《cursor-单独登录-App文案-两端对齐》). When the CLI is not known to have
/// `login cursor`, a kept sign-in still shows its state and 退出, without the
/// sign-in buttons. No explanatory line (maintainer, 2026-11-26): what the
/// sign-in is and does is in the README.
struct CursorLoginBlock: View {
    @Environment(AppState.self) private var appState
    @Environment(\.settingsTheme) private var theme
    @State private var confirmingSignOut = false

    static let waitingText = "请在浏览器里确认；如果 Cursor 让你去邮箱确认，点完邮件里的链接再回来"
    /// One sentence (maintainer, 2026-11-26: 「字写得也太多了吧」); how to
    /// revoke it on cursor.com is in the README's privacy notes.
    static let signOutMessage = "只删除 Vibe Usage 里的这份登录，Cursor 编辑器不受影响。"

    private var login: CursorLogin { appState.cursorLogin }
    private var canSignIn: Bool { login.cliSupportsSignIn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.isModern ? 6 : 8) {
            HStack(alignment: .center, spacing: 8) {
                state
                    .frame(maxWidth: .infinity, alignment: .leading)
                action
            }
            if let error = login.errorText, login.phase != .waiting {
                Text(error)
                    .font(theme.caption)
                    .foregroundStyle(theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.isModern ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.configBlock)
            }
        }
        .alert("退出 Cursor 登录？", isPresented: $confirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { login.signOut() }
        } message: {
            Text(Self.signOutMessage)
        }
    }

    @ViewBuilder
    private var state: some View {
        switch login.phase {
        case .signedOut:
            Text("未登录")
                .font(theme.body)
                .foregroundStyle(theme.secondaryText)
        case .waiting:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(Self.waitingText)
                    .font(theme.body)
                    .foregroundStyle(theme.text)
                    .lineSpacing(theme.isModern ? 2 : 0)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .signedIn(let email):
            HStack(spacing: 6) {
                SettingsCheckMark()
                Text(email ?? "Cursor 账号")
                    .font(theme.body)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(email ?? "Cursor 账号")
            }
        case .expired:
            Text("登录已失效")
                .font(theme.body)
                .foregroundStyle(theme.amber)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch login.phase {
        case .signedOut:
            if canSignIn {
                Button("登录") { login.signIn() }
                    .buttonStyle(.settings)
            }
        case .waiting:
            Button("取消") { login.cancelSignIn() }
                .buttonStyle(.settings)
        case .signedIn:
            Button("退出") { confirmingSignOut = true }
                .buttonStyle(.settings)
        case .expired:
            // 退出 too: Cursor already ended it, so nothing to revoke and no
            // confirmation; without it the ended sign-in would keep Cursor's
            // own login on this Mac from being read until the user signs in.
            HStack(spacing: 8) {
                Button("退出") { login.signOut() }
                    .buttonStyle(.settings)
                if canSignIn {
                    Button("重新登录") { login.signIn() }
                        .buttonStyle(.settings)
                }
            }
        }
    }
}
