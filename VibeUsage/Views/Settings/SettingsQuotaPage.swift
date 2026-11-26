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
                    Text("\(enabled.count) / \(appState.quotaProducts.count) 已开启 · 拖动排序")
                        .font(SettingsTheme.body)
                        .monospacedDigit()
                        .foregroundStyle(SettingsTheme.secondaryText)
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
                SettingsSectionTitle(title: "隐私保护")
                EgressSettingsCard()
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

    private var table: some View {
        SettingsCard {
            QuotaTableHeader()
            rows(enabled)
            if !disabled.isEmpty {
                Text("未开启")
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background { Rectangle().fill(SettingsTheme.band) }
                rows(disabled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// 工具 · 状态 · 面板卡片, aligned with the row columns.
/// The egress check's one setting (`EgressCheck.Mode`), a pop-up menu like
/// System Settings' 「显示滚动条」: what Codex, Claude, Grok and Antigravity do when
/// no proxy is detected. What each option does is in the README, not here
/// (maintainer, 2026-11-26: no explanatory sentences in Settings).
private struct EgressSettingsCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsCard {
            SettingsRow {
                SettingsRowLabel(title: "没检测到代理时")
                Spacer(minLength: 8)
                Picker("没检测到代理时", selection: Binding(
                    get: { appState.egressMode },
                    set: { appState.egressMode = $0 }
                )) {
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

private struct QuotaTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("工具")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("状态")
                .frame(width: QuotaProductRow.statusWidth, alignment: .leading)
            Text("面板卡片")
                .fixedSize()
                .frame(width: 30, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }
        .font(SettingsTheme.caption)
        .foregroundStyle(SettingsTheme.secondaryText)
        .padding(.leading, QuotaProductRow.nameInset)
        .padding(.trailing, 12)
        .frame(height: 28)
        .overlay(alignment: .bottom) { SettingsTheme.line.frame(height: 1) }
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
    /// Column metrics shared with the header (design: 状态 124 wide; names
    /// start 58 pt in, after the disclosure slot and the 22 pt mark).
    static let statusWidth: CGFloat = 124
    static let nameInset: CGFloat = 58
    static let rowHeight: CGFloat = 40

    let provider: ProviderRateLimit.Provider
    let drag: QuotaDragState
    let enabled: [ProviderRateLimit.Provider]
    let disabled: [ProviderRateLimit.Provider]

    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
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
                    move: { appState.moveQuotaProduct($0, before: $1) }
                ))
            if isConfigurable, isExpanded {
                Group {
                    if provider == .cursor {
                        CursorLoginBlock()
                    } else {
                        ZCodeConfigBlock()
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
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
                ProviderGlyph(provider: provider, size: 18)
                    .foregroundStyle(isOn ? SettingsTheme.text : SettingsTheme.secondaryText)
                    .opacity(isOn ? 1 : 0.72)
                    .frame(width: 22, height: 22)
                Text(provider.displayName)
                    .font(SettingsTheme.label)
                    .foregroundStyle(isOn ? SettingsTheme.text : SettingsTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .frame(height: Self.rowHeight)
        .overlay(alignment: .leading) {
            if isConfigurable {
                Button(action: toggleExpanded) {
                    DisclosureTriangle(isOpen: isExpanded)
                        .frame(width: 12, height: 12)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 6)
                .help(isExpanded ? "收起" : "展开")
                .accessibilityLabel(isExpanded ? "收起 \(provider.displayName)" : "展开 \(provider.displayName)")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SettingsTheme.selection)
                .padding(.horizontal, 4)
                .opacity(flash ? 1 : 0)
        }
        .overlay(alignment: indicatorEdge ?? .top) {
            if indicatorEdge != nil {
                SettingsTheme.green
                    .frame(height: 2)
                    .clipShape(Capsule())
                    .padding(.horizontal, 10)
                    .offset(y: indicatorEdge == .top ? -1 : 1)
            }
        }
        .contentShape(Rectangle())
        .onDrag {
            drag.begin(provider)
            return NSItemProvider(object: provider.rawValue as NSString)
        } preview: {
            QuotaDragPreview(provider: provider, isOn: isOn, status: statusValue)
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

/// Six dots, always visible: the row can be dragged anywhere, the handle says so.
private struct DragHandle: View {
    let dimmed: Bool

    var body: some View {
        Canvas { context, _ in
            for x in [2.6, 7.4] {
                for y in [3.0, 8.0, 13.0] {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                        with: .color(SettingsTheme.tertiaryText)
                    )
                }
            }
        }
        .frame(width: 10, height: 16)
        .opacity(dimmed ? 0.38 : 0.75)
        .onHover { inside in
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .help("拖动排序")
        .accessibilityHidden(true)
    }
}

/// The row-start triangle: right when closed, down when open.
struct DisclosureTriangle: View {
    let isOpen: Bool

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 4.3, y: 2.3))
            path.addLine(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 4.3, y: 9.7))
        }
        .stroke(SettingsTheme.secondaryText, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}

private struct QuotaStatusCell: View {
    let value: (kind: SettingsStatusKind, text: String)
    let isOn: Bool

    private var textColor: Color {
        switch value.kind {
        case .warning: SettingsTheme.amber
        case .error: SettingsTheme.red
        case .ok, .none: isOn ? SettingsTheme.text : SettingsTheme.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            SettingsStatusDot(kind: value.kind, dimmed: !isOn)
            Text(value.text)
                .font(SettingsTheme.body)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .frame(width: QuotaProductRow.statusWidth, alignment: .leading)
    }
}

/// What follows the pointer while a row is dragged: the row, lifted.
private struct QuotaDragPreview: View {
    let provider: ProviderRateLimit.Provider
    let isOn: Bool
    let status: (kind: SettingsStatusKind, text: String)

    var body: some View {
        HStack(spacing: 10) {
            ProviderGlyph(provider: provider, size: 18)
                .foregroundStyle(SettingsTheme.text)
                .frame(width: 22, height: 22)
            Text(provider.displayName)
                .font(SettingsTheme.label)
                .foregroundStyle(SettingsTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            QuotaStatusCell(value: status, isOn: isOn)
            Capsule()
                .fill(isOn ? SettingsTheme.green : SettingsTheme.switchTrack)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(SettingsTheme.switchKnob).frame(width: 14, height: 14).padding(2)
                }
                .frame(width: 30, height: 18)
        }
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .frame(width: 440, height: 40)
        .background(SettingsTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SettingsTheme.strongLine, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Drop

private struct QuotaRowDropDelegate: DropDelegate {
    let row: ProviderRateLimit.Provider
    let drag: QuotaDragState
    let enabled: [ProviderRateLimit.Provider]
    let disabled: [ProviderRateLimit.Provider]
    let move: @MainActor (ProviderRateLimit.Provider, ProviderRateLimit.Provider?) -> Void

    private func target(_ info: DropInfo) -> QuotaReorder.Target {
        QuotaReorder.target(
            dragged: drag.dragged,
            row: row,
            dropAfter: info.location.y > QuotaProductRow.rowHeight / 2,
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
        let after = info.location.y > QuotaProductRow.rowHeight / 2
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
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
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
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SettingsTheme.green)
                        Text("Key 已保存")
                            .font(SettingsTheme.body)
                            .foregroundStyle(SettingsTheme.text)
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
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(error)
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.configBlock, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
/// §3): 未登录 → 登录 (no text); waiting for the browser → 取消; signed in (the
/// account's email) → 退出; ended or lapsed → 退出 / 重新登录. How to revoke it on
/// cursor.com is in the README, not in the app. The copy is
/// word for word the Windows app's (workspace notes
/// 《cursor-单独登录-App文案-两端对齐》). When the CLI is not known to have
/// `login cursor`, a kept sign-in still shows its state and 退出, without the
/// sign-in buttons. No explanatory line (maintainer, 2026-11-26): what the
/// sign-in is and does is in the README.
struct CursorLoginBlock: View {
    @Environment(AppState.self) private var appState
    @State private var confirmingSignOut = false

    static let waitingText = "请在浏览器里确认；如果 Cursor 让你去邮箱确认，点完邮件里的链接再回来"
    /// One sentence (maintainer, 2026-11-26: 「字写得也太多了吧」); how to
    /// revoke it on cursor.com is in the README's privacy notes.
    static let signOutMessage = "只删除 Vibe Usage 里的这份登录，Cursor 编辑器不受影响。"

    private var login: CursorLogin { appState.cursorLogin }
    private var canSignIn: Bool { login.cliSupportsSignIn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                state
                    .frame(maxWidth: .infinity, alignment: .leading)
                action
            }
            if let error = login.errorText, login.phase != .waiting {
                Text(error)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.configBlock, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            // No words: the button sits where every state's button sits.
            Color.clear.frame(height: 1)
        case .waiting:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(Self.waitingText)
                    .font(SettingsTheme.body)
                    .foregroundStyle(SettingsTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .signedIn(let email):
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SettingsTheme.green)
                Text(email ?? "Cursor 账号")
                    .font(SettingsTheme.body)
                    .foregroundStyle(SettingsTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(email ?? "Cursor 账号")
            }
        case .expired:
            Text("登录已失效")
                .font(SettingsTheme.body)
                .foregroundStyle(SettingsTheme.amber)
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
