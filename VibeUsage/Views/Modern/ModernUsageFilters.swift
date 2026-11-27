import AppKit
import SwiftUI

/// The filter menu of 近期消耗 (134e–134k). It is drawn by the panel's root
/// overlay (`UsageFilterMenuOverlay`), not next to its button: the cards
/// scroll and the menu hangs over the next card and the footer. One menu per
/// panel; it closes on a click outside, Escape, a period choice, 「应用」,
/// 「清除筛选」, and whenever the panel opens again.
@MainActor
@Observable
final class UsageFilterMenuState {
    nonisolated static let space = "modernPanel"

    enum Submenu: Int, CaseIterable {
        case time, terminal, tool, model

        var title: String {
            switch self {
            case .time: "时间"
            case .terminal: "终端"
            case .tool: "工具"
            case .model: "模型"
            }
        }
    }

    private(set) var isOpen = false
    var submenu: Submenu?
    /// The filter button's frame in `space`.
    var anchor: CGRect = .zero
    /// 「自定义日期」 picked in the time submenu but not applied yet.
    var customDraft: (from: Date, to: Date)?
    var expandedFamilies: Set<String> = []
    /// Off-screen renders: open once, as the preview asks.
    @ObservationIgnored var appliedPreview = false

    func open(_ submenu: Submenu? = nil) {
        isOpen = true
        self.submenu = submenu
        customDraft = nil
    }

    func close() {
        isOpen = false
        submenu = nil
        customDraft = nil
    }
}

// MARK: - Title row (134a, 134g, 134i, 134j)

/// The right side of 近期消耗's title row. The rule from the design: a lit
/// chip is a condition in effect — the quick period, the custom dates, each
/// filter (「Codex +1」) — then the filter icon. Clicking a filter chip opens
/// the menu on its row.
struct RecentUsageControls: View {
    @Environment(AppState.self) private var appState
    @Environment(UsageFilterMenuState.self) private var menu
    @Environment(\.recentUsagePreview) private var preview

    var body: some View {
        let chips = UsageFilterChips(appState: appState)
        HStack(spacing: 2) {
            // With many conditions the quick periods that are not in effect
            // step aside (the time submenu still has them); what is lit
            // always stays.
            ViewThatFits(in: .horizontal) {
                conditions(chips, allPeriods: true)
                conditions(chips, allPeriods: false)
            }
            filterButton
        }
        // The icon's padding hangs past the text edge (`margin-right: -7px`).
        .padding(.trailing, -7)
        .onChange(of: appState.modernPanel.presentation) { menu.close() }
        .onDisappear { menu.close() }
    }

    private func conditions(_ chips: UsageFilterChips, allPeriods: Bool) -> some View {
        let periods = UsageFilterSummary.quickPeriods.filter { allPeriods || appState.timeRange == $0 }
        return HStack(spacing: 2) {
            ForEach(periods, id: \.self) { range in
                RecentUsageChip(
                    title: UsageFilterSummary.periodLabel(range),
                    isMono: range != .today,
                    isOn: appState.timeRange == range
                ) {
                    selectPeriod(range)
                }
                .fixedSize()
            }
            let hasConditions = appState.timeRange == .custom || !chips.filters.isEmpty
            if !periods.isEmpty, allPeriods || hasConditions {
                Rectangle()
                    .fill(ModernTheme.text.opacity(0.16))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 4)
            }
            if appState.timeRange == .custom {
                RecentUsageChip(title: chips.custom, isMono: true, isOn: true) { menu.open(.time) }
                    .fixedSize()
            }
            ForEach(chips.filters, id: \.submenu) { chip in
                RecentUsageChip(title: chip.title, isMono: false, isOn: true) { menu.open(chip.submenu) }
                    .help(chip.title)
                    // The full row must fit as it is; only the last resort truncates.
                    .fixedSize(horizontal: allPeriods, vertical: false)
            }
        }
    }

    private var filterButton: some View {
        Button {
            if menu.isOpen { menu.close() } else { menu.open() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12, height: 20)
                .padding(.horizontal, 7)
                .background(Capsule().fill(menu.isOpen ? ModernTheme.chip : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(ModernIconButtonStyle(color: menu.isOpen ? ModernTheme.text : ModernTheme.secondaryText))
        .help("筛选")
        .accessibilityLabel("筛选")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(UsageFilterMenuState.space)) } action: { frame in
            menu.anchor = frame
            if let wanted = preview.menu, !menu.appliedPreview {
                menu.appliedPreview = true
                menu.open(wanted)
                menu.expandedFamilies = preview.expandedFamilies
            }
        }
    }

    private func selectPeriod(_ range: TimeRange) {
        guard appState.timeRange != range else { return }
        appState.timeRange = range
        Task { await appState.fetchUsageData() }
    }
}

/// The lit chips and the menu's row values, from the classic filter state
/// (no project) and the selected subscription.
@MainActor
struct UsageFilterChips {
    struct Chip {
        let submenu: UsageFilterMenuState.Submenu
        let title: String
    }

    let custom: String
    let filters: [Chip]
    /// The tool a selected subscription stands for (the 工具 row is locked to
    /// it); nil on 概览.
    let lockedTool: String?
    private let values: [UsageFilterMenuState.Submenu: String]

    init(appState: AppState) {
        let bounds = appState.normalizedCustomRange
        custom = UsageFilterSummary.customLabel(from: bounds.from, to: bounds.to)
        let enabled = appState.quotaCardProviders
        let subscription = enabled.count > 1 ? appState.modernPanel.focusedSubscription(enabled: enabled) : nil
        lockedTool = subscription.map { provider in
            let source = provider.usageSource
            let name = appState.toolName(source)
            return name == source ? provider.displayName : name
        }
        let filters = appState.filters
        var values: [UsageFilterMenuState.Submenu: String] = [:]
        values[.terminal] = UsageFilterSummary.label(Array(filters.hostnames))
        values[.tool] = lockedTool ?? UsageFilterSummary.label(filters.sources.map(appState.toolName))
        values[.model] = UsageFilterSummary.label(Array(filters.models))
        self.values = values
        var chips: [Chip] = []
        for submenu in [UsageFilterMenuState.Submenu.terminal, .tool, .model] {
            // Inside a subscription its tool is the card itself, not a chip (131b).
            if submenu == .tool, lockedTool != nil { continue }
            if let title = values[submenu] { chips.append(Chip(submenu: submenu, title: title)) }
        }
        self.filters = chips
    }

    /// The value after a row's label: the period, or 「全部」.
    func value(_ submenu: UsageFilterMenuState.Submenu, period: TimeRange) -> (text: String, isSet: Bool, isMono: Bool) {
        if submenu == .time {
            let text = period == .custom ? custom : UsageFilterSummary.periodLabel(period)
            return (text, true, period != .today)
        }
        if let text = values[submenu] { return (text, true, false) }
        return ("全部", false, false)
    }
}

/// A title-row chip: 20 pt, 8 pt padding; lit at 10 % with the primary
/// color, otherwise secondary and brightening under the pointer.
private struct RecentUsageChip: View {
    let title: String
    let isMono: Bool
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isMono ? ModernTheme.mono(11, isOn ? .medium : .regular)
                    : ModernTheme.text(11, isOn ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(isOn ? ModernTheme.chip : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(ModernTextButtonStyle(color: isOn ? ModernTheme.text : ModernTheme.secondaryText))
    }
}

// MARK: - Menu overlay (134e–134k)

/// The panel-level layer that draws the open menu and its submenu.
struct UsageFilterMenuOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(UsageFilterMenuState.self) private var menu

    var body: some View {
        if menu.isOpen {
            GeometryReader { proxy in
                let main = UsageFilterMenuLayout.mainFrame(anchor: menu.anchor, container: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { menu.close() }
                    UsageFilterMainMenu()
                        .frame(width: main.width, height: main.height)
                        .offset(x: main.minX, y: main.minY)
                    if let submenu = menu.submenu {
                        UsageFilterSubmenu(submenu: submenu, main: main, container: proxy.size)
                    }
                }
            }
        }
    }
}

/// Sizes from the design: 186 pt wide, 6 pt padding, 26 pt rows, a rule,
/// 「清除筛选」 on a 24 pt row; 4 pt under the filter icon, right edges
/// aligned. Submenus open 4 pt to the left, their first row level with the
/// row that opened them, kept inside the panel.
enum UsageFilterMenuLayout {
    static let width: CGFloat = 186
    static let padding: CGFloat = 6
    static let rowHeight: CGFloat = 26
    static let edgeInset: CGFloat = 8
    static let height: CGFloat = padding * 2 + rowHeight * 4 + 7 + 24

    static func mainFrame(anchor: CGRect, container: CGSize) -> CGRect {
        var x = anchor.maxX - width
        x = min(max(x, edgeInset), container.width - edgeInset - width)
        var y = anchor.minY + 24
        y = min(y, container.height - edgeInset - height)
        return CGRect(x: x, y: max(edgeInset, y), width: width, height: height)
    }

    static func subFrame(main: CGRect, row: Int, size: CGSize, container: CGSize) -> CGRect {
        let height = min(size.height, container.height - 2 * edgeInset)
        var y = main.minY + rowHeight * CGFloat(row)
        y = min(y, container.height - edgeInset - height)
        let x = max(edgeInset, main.minX - 4 - size.width)
        return CGRect(x: x, y: max(edgeInset, y), width: size.width, height: height)
    }
}

/// 时间 / 终端 / 工具 / 模型, a rule, 「清除筛选」. It takes the keyboard
/// focus when it opens, so Escape closes it.
private struct UsageFilterMainMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(UsageFilterMenuState.self) private var menu
    @FocusState private var focused: Bool

    var body: some View {
        let chips = UsageFilterChips(appState: appState)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(UsageFilterMenuState.Submenu.allCases, id: \.self) { submenu in
                row(submenu, chips: chips)
            }
            Rectangle()
                .fill(ModernTheme.text.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            UsageMenuRow(height: 24, isHighlighted: false) {
                Text("清除筛选")
                    .font(ModernTheme.text(13))
                    .foregroundStyle(ModernTheme.secondaryText)
            } action: {
                appState.filters.clearUsagePanelFilters()
                menu.close()
            }
        }
        .padding(UsageFilterMenuLayout.padding)
        .frame(width: UsageFilterMenuLayout.width, alignment: .topLeading)
        .background(RecentUsageBlockBackground(cornerRadius: 10))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            menu.close()
            return .handled
        }
    }

    @ViewBuilder
    private func row(_ submenu: UsageFilterMenuState.Submenu, chips: UsageFilterChips) -> some View {
        let value = chips.value(submenu, period: appState.timeRange)
        let isLocked = submenu == .tool && chips.lockedTool != nil
        UsageMenuRow(height: UsageFilterMenuLayout.rowHeight, isHighlighted: menu.submenu == submenu) {
            HStack(spacing: 8) {
                Text(submenu.title)
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .fixedSize()
                Text(value.text)
                    .font(value.isMono ? ModernTheme.mono(13, value.isSet ? .medium : .regular)
                        : ModernTheme.text(13, value.isSet ? .medium : .regular))
                    .foregroundStyle(value.isSet ? ModernTheme.text : ModernTheme.strongText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !isLocked {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(ModernTheme.secondaryText)
                }
            }
        } action: {
            guard !isLocked else { return }
            menu.submenu = menu.submenu == submenu ? nil : submenu
            menu.customDraft = nil
        }
        .disabled(isLocked)
    }
}

/// A menu row: 8 pt padding, 6 pt corners, 8 % under the pointer or while
/// its submenu is open.
private struct UsageMenuRow<Label: View>: View {
    var height: CGFloat
    var leading: CGFloat = 8
    var isHighlighted: Bool
    @ViewBuilder var label: Label
    var action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .padding(.leading, leading)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ModernTheme.text.opacity(isHighlighted || isHovered && isEnabled ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A submenu: the period list with 「自定义日期」 (134h), or a lamp list
/// where 「全部」 clears the dimension and every other row toggles (134f,
/// 134j); models in families, a lamp that selects the whole family and a
/// chevron that opens it (134k).
private struct UsageFilterSubmenu: View {
    @Environment(AppState.self) private var appState
    @Environment(UsageFilterMenuState.self) private var menu
    let submenu: UsageFilterMenuState.Submenu
    let main: CGRect
    let container: CGSize
    @State private var contentHeight: CGFloat = 0

    private var width: CGFloat {
        switch submenu {
        case .time: 204
        case .terminal: 184
        case .tool: 150
        case .model: 184
        }
    }

    var body: some View {
        let frame = UsageFilterMenuLayout.subFrame(
            main: main, row: submenu.rawValue,
            size: CGSize(width: width, height: contentHeight), container: container
        )
        ScrollView(.vertical) {
            list
                .padding(UsageFilterMenuLayout.padding)
                .frame(width: width, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: frame.height)
        .background(RecentUsageBlockBackground(cornerRadius: 10))
        .offset(x: frame.minX, y: frame.minY)
        .opacity(contentHeight > 0 ? 1 : 0)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch submenu {
            case .time: timeList
            case .terminal:
                lampList(values: Set(appState.buckets.map(\.hostname)).sorted(by: Self.reading),
                         label: { $0.isEmpty ? "未知" : $0 }, selected: \.hostnames)
            case .tool:
                lampList(values: Set(appState.buckets.map(\.source)).sorted {
                    Self.reading(appState.toolName($0), appState.toolName($1))
                }, label: { appState.toolName($0) }, selected: \.sources)
            case .model: modelList
            }
        }
    }

    private static func reading(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    // MARK: Time

    @ViewBuilder
    private var timeList: some View {
        let customOn = menu.customDraft != nil || appState.timeRange == .custom
        ForEach(UsageFilterSummary.quickPeriods, id: \.self) { range in
            lampRow(UsageFilterSummary.periodLabel(range), state: !customOn && appState.timeRange == range ? .on : .off,
                    isMono: range != .today) {
                if appState.timeRange != range {
                    appState.timeRange = range
                    Task { await appState.fetchUsageData() }
                }
                menu.close()
            }
        }
        lampRow("自定义日期", state: customOn ? .on : .off) {
            let bounds = appState.normalizedCustomRange
            menu.customDraft = (bounds.from, bounds.to)
        }
        if customOn {
            UsageCustomDates()
        }
    }

    // MARK: Lamp lists

    private func lampList(values: [String], label: @escaping (String) -> String,
                          selected: WritableKeyPath<FilterState, Set<String>>) -> some View {
        let chosen = appState.filters[keyPath: selected]
        return VStack(alignment: .leading, spacing: 0) {
            lampRow("全部", state: chosen.isEmpty ? .on : .off) {
                appState.filters[keyPath: selected].removeAll()
            }
            ForEach(values, id: \.self) { value in
                lampRow(label(value), state: chosen.contains(value) ? .on : .off) {
                    toggle(value, in: selected)
                }
                .help(label(value))
            }
        }
    }

    private func toggle(_ value: String, in keyPath: WritableKeyPath<FilterState, Set<String>>) {
        if appState.filters[keyPath: keyPath].contains(value) {
            appState.filters[keyPath: keyPath].remove(value)
        } else {
            appState.filters[keyPath: keyPath].insert(value)
        }
    }

    @ViewBuilder
    private var modelList: some View {
        let chosen = appState.filters.models
        lampRow("全部", state: chosen.isEmpty ? .on : .off) {
            appState.filters.models.removeAll()
        }
        ForEach(appState.modelFilterGroups) { group in
            let members = Set(group.models)
            let picked = members.intersection(chosen)
            let state: UsageMenuLamp.State = picked.isEmpty ? .off : picked.count == members.count ? .on : .mixed
            let isExpanded = menu.expandedFamilies.contains(group.key)
            HStack(spacing: 0) {
                lampRow(group.label, state: state) {
                    if state == .on {
                        appState.filters.models.subtract(members)
                    } else {
                        appState.filters.models.formUnion(members)
                    }
                }
                Button {
                    if isExpanded { menu.expandedFamilies.remove(group.key) } else { menu.expandedFamilies.insert(group.key) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(ModernTheme.secondaryText)
                        .frame(width: 26, height: UsageFilterMenuLayout.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -26)
            }
            if isExpanded {
                ForEach(group.models, id: \.self) { model in
                    lampRow(model.isEmpty ? "未知" : model, state: chosen.contains(model) ? .on : .off, indent: 28) {
                        toggle(model, in: \.models)
                    }
                    .help(model)
                }
            }
        }
    }

    private func lampRow(_ title: String, state: UsageMenuLamp.State, isMono: Bool = false, indent: CGFloat = 8,
                         action: @escaping () -> Void) -> some View {
        UsageMenuRow(height: UsageFilterMenuLayout.rowHeight, leading: indent, isHighlighted: false) {
            HStack(spacing: 8) {
                UsageMenuLamp(state: state)
                Text(title)
                    .font(isMono ? ModernTheme.mono(13, state == .off ? .regular : .medium)
                        : ModernTheme.text(13, state == .off ? .regular : .medium))
                    .foregroundStyle(state == .off ? ModernTheme.strongText : ModernTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        } action: {
            action()
        }
    }
}

/// The small lamp before a menu choice: a dark well, lit when chosen, a
/// short bar when part of a family is chosen (134k).
struct UsageMenuLamp: View {
    enum State: Equatable { case off, on, mixed }
    let state: State

    var body: some View {
        if state == .mixed {
            ZStack {
                ModernLamp(isOn: false)
                Circle().fill(ModernTheme.well).frame(width: 7, height: 7)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(settingsHex: 0xC9CDD1))
                    .frame(width: 6, height: 2)
            }
            .frame(width: 12, height: 12)
        } else {
            ModernLamp(isOn: state == .on)
        }
    }
}

/// 134h: the two dates and 「应用」. The dates are drafts until 「应用」,
/// which counts through the whole last day (#100) and fetches the range.
private struct UsageCustomDates: View {
    @Environment(AppState.self) private var appState
    @Environment(UsageFilterMenuState.self) private var menu

    var body: some View {
        let draft = menu.customDraft ?? (appState.normalizedCustomRange.from, appState.normalizedCustomRange.to)
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 5) {
                field(draft.from) { menu.customDraft = ($0, draft.to) }
                Text("–")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .fixedSize()
                field(draft.to) { menu.customDraft = (draft.from, $0) }
            }
            .padding(.top, 2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                apply(draft)
            } label: {
                Text("应用")
                    .font(ModernTheme.text(11, .semibold))
                    .foregroundStyle(ModernTheme.prominentLabel)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ModernTheme.text))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }

    private func field(_ date: Date, set: @escaping (Date) -> Void) -> some View {
        ModernDateField(date: date, onChange: set)
            .frame(width: 64, height: 14)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ModernTheme.text.opacity(0.08)))
    }

    private func apply(_ draft: (from: Date, to: Date)) {
        let calendar = Calendar.current
        appState.customRangeFrom = calendar.startOfDay(for: draft.from)
        appState.customRangeTo = calendar.startOfDay(for: draft.to)
        appState.timeRange = .custom
        menu.close()
        Task { await appState.fetchUsageData() }
    }
}

/// A borderless system date field: year, month and day, typed or stepped
/// with the arrow keys.
private struct ModernDateField: NSViewRepresentable {
    let date: Date
    let onChange: (Date) -> Void

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        // A fixed numeric year-month-day (2026-11-03) that fits the pill:
        // the user's own short format can be 「2026年11月 3日」.
        picker.locale = Locale(identifier: "sv_SE")
        picker.font = NSFont(name: "JetBrainsMono-Regular", size: 11) ?? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        picker.textColor = NSColor(ModernTheme.text)
        picker.maxDate = Date()
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = date
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.onChange = onChange
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Date) -> Void
        init(onChange: @escaping (Date) -> Void) { self.onChange = onChange }

        @objc func changed(_ sender: NSDatePicker) {
            onChange(sender.dateValue)
        }
    }
}
