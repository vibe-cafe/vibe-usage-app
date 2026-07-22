import SwiftUI

private enum FilterDimension: CaseIterable {
    case hostname
    case source
    case model
    case project

    var icon: String {
        switch self {
        case .hostname: "desktopcomputer"
        case .source: "terminal"
        case .model: "cpu"
        case .project: "folder"
        }
    }

    var label: String {
        switch self {
        case .hostname: "终端"
        case .source: "工具"
        case .model: "模型"
        case .project: "项目"
        }
    }
}

struct FilterTagsView: View {
    @Environment(AppState.self) private var appState
    @State private var openFilter: FilterDimension?
    @State private var expandedModelFamilies: Set<String> = Set()
    private let filterGap: CGFloat = 8
    private let filterRowHeight: CGFloat = 28
    private let dropdownWidth: CGFloat = 240
    private let dropdownMaxHeight: CGFloat = 260

    private var uniqueSources: [String] {
        Array(Set(appState.buckets.map(\.source))).sorted()
    }

    private var uniqueModels: [String] {
        Array(Set(appState.buckets.map(\.model))).sorted()
    }

    private var uniqueProjects: [String] {
        Array(Set(appState.buckets.map(\.project))).sorted()
    }

    private var uniqueHostnames: [String] {
        Array(Set(appState.buckets.map(\.hostname))).sorted()
    }

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                timeRangeSelector

                Spacer(minLength: 0)

                if !appState.filters.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            state.filters.clear()
                        }
                    } label: {
                        Text("清除")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("清除筛选")
                }
            }

            if appState.timeRange == .custom {
                customRangeControls
            }

            filterGrid
                .zIndex(20)
        }
    }

    private var filterGrid: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let count = CGFloat(FilterDimension.allCases.count)
            let buttonWidth = max((availableWidth - filterGap * (count - 1)) / count, 0)
            let panelWidth = min(dropdownWidth, max(availableWidth, 0))

            ZStack(alignment: .topLeading) {
                HStack(spacing: filterGap) {
                    ForEach(FilterDimension.allCases, id: \.self) { dimension in
                        filterButton(for: dimension)
                            .frame(width: buttonWidth)
                    }
                }
                .frame(width: availableWidth, height: filterRowHeight, alignment: .leading)

                if let openFilter {
                    filterPanel(for: openFilter)
                        .frame(width: panelWidth, height: dropdownHeight(for: openFilter))
                        .offset(
                            x: dropdownX(for: openFilter, in: availableWidth, panelWidth: panelWidth),
                            y: filterRowHeight + 6
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .zIndex(20)
                }
            }
        }
        .frame(height: filterRowHeight)
    }

    private var timeRangeSelector: some View {
        HStack(spacing: 1) {
            ForEach(TimeRange.allCases, id: \.rawValue) { range in
                let isActive = appState.timeRange == range
                Button {
                    guard appState.timeRange != range else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.timeRange = range
                    }
                    Task { await appState.fetchUsageData() }
                } label: {
                    Text(displayLabel(for: range))
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.white : Color(white: 0.54))
                        .frame(height: 24)
                        .padding(.horizontal, 9)
                        .background(isActive ? Color(white: 0.20) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(white: 0.10))
        .clipShape(Capsule())
    }

    private var customRangeControls: some View {
        HStack(spacing: 8) {
            DatePicker(
                "",
                selection: Binding(
                    get: { appState.customRangeFrom },
                    set: { appState.customRangeFrom = Calendar.current.startOfDay(for: $0) }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .controlSize(.small)

            Text("–")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.38))

            DatePicker(
                "",
                selection: Binding(
                    get: { appState.customRangeTo },
                    set: { appState.customRangeTo = Calendar.current.startOfDay(for: $0) }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                Task { await appState.fetchUsageData() }
            } label: {
                Text("应用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.14), lineWidth: 1))
    }

    private func filterButton(for dimension: FilterDimension) -> some View {
        let enabled = hasValues(for: dimension)
        let selectedCount = selectedValues(for: dimension).count
        let isOpen = openFilter == dimension
        let isActive = selectedCount > 0
        let summary = summaryText(for: dimension)

        return Button {
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                openFilter = isOpen ? nil : dimension
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: dimension.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive || isOpen ? Color.white : Color(white: 0.58))
                    .frame(width: 13)
                    .layoutPriority(1)

                Text(dimension.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive || isOpen ? Color.white : Color(white: 0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(2)

                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color(white: 0.86) : Color(white: 0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(white: 0.38))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 10)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: filterRowHeight)
            .background(isActive || isOpen ? Color(white: 0.16) : Color(white: 0.09))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(white: isActive || isOpen ? 0.26 : 0.15), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .clipped()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func filterPanel(for dimension: FilterDimension) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                panelContent(for: dimension)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: dropdownScrollHeight(for: dimension))
        }
        .padding(.vertical, 4)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.18), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
    }

    private func dropdownX(for dimension: FilterDimension, in width: CGFloat, panelWidth: CGFloat) -> CGFloat {
        guard width > panelWidth else { return 0 }
        let index = CGFloat(FilterDimension.allCases.firstIndex(of: dimension) ?? 0)
        let buttonWidth = (width - filterGap * CGFloat(FilterDimension.allCases.count - 1)) / CGFloat(FilterDimension.allCases.count)
        let buttonCenter = index * (buttonWidth + filterGap) + buttonWidth / 2
        let centered = buttonCenter - panelWidth / 2
        return min(max(0, centered), width - panelWidth)
    }

    private func dropdownHeight(for dimension: FilterDimension) -> CGFloat {
        dropdownScrollHeight(for: dimension) + 8
    }

    private func dropdownScrollHeight(for dimension: FilterDimension) -> CGFloat {
        min(max(CGFloat(visibleRowCount(for: dimension)) * 28, 28), dropdownMaxHeight - 8)
    }

    private func visibleRowCount(for dimension: FilterDimension) -> Int {
        switch dimension {
        case .hostname:
            return max(uniqueHostnames.count, 1)
        case .source:
            return max(uniqueSources.count, 1)
        case .project:
            return max(uniqueProjects.count, 1)
        case .model:
            var count = 0
            for group in groupModelsByFamily(uniqueModels) {
                let familyKey = group.family?.key ?? "other"
                count += 1
                if expandedModelFamilies.contains(familyKey) {
                    count += group.models.count
                }
            }
            return max(count, 1)
        }
    }

    @ViewBuilder
    private func panelContent(for dimension: FilterDimension) -> some View {
        switch dimension {
        case .hostname:
            optionFlow(values: uniqueHostnames, selected: appState.filters.hostnames) { value in
                toggle(value, in: &appState.filters.hostnames)
            }
        case .source:
            optionFlow(values: uniqueSources, selected: appState.filters.sources) { value in
                toggle(value, in: &appState.filters.sources)
            }
        case .model:
            modelOptions
        case .project:
            optionFlow(values: uniqueProjects, selected: appState.filters.projects) { value in
                toggle(value, in: &appState.filters.projects)
            }
        }
    }

    private func optionFlow(values: [String], selected: Set<String>, toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(values, id: \.self) { value in
                optionRow(title: value.isEmpty ? "未知" : value, isSelected: selected.contains(value)) {
                    toggle(value)
                }
            }
        }
    }

    private var modelOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groupModelsByFamily(uniqueModels).enumerated()), id: \.offset) { _, group in
                let familyKey = group.family?.key ?? "other"
                let familyLabel = group.family?.label ?? "其他"
                let familyModels = Set(group.models)
                let selectedInFamily = familyModels.intersection(appState.filters.models)
                let allSelected = selectedInFamily.count == familyModels.count && !familyModels.isEmpty
                let someSelected = !selectedInFamily.isEmpty && !allSelected
                let isExpanded = expandedModelFamilies.contains(familyKey)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if allSelected {
                                    appState.filters.models.subtract(familyModels)
                                } else {
                                    appState.filters.models.formUnion(familyModels)
                                }
                            }
                        } label: {
                            checkRowContent(
                                title: familyLabel,
                                isSelected: allSelected,
                                isMixed: someSelected
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                if isExpanded {
                                    expandedModelFamilies.remove(familyKey)
                                } else {
                                    expandedModelFamilies.insert(familyKey)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(white: 0.38))
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }

                    if isExpanded {
                        ForEach(group.models, id: \.self) { value in
                            optionRow(title: value.isEmpty ? "未知" : value, isSelected: appState.filters.models.contains(value), indent: 19) {
                                toggle(value, in: &appState.filters.models)
                            }
                        }
                    }
                }
            }
        }
    }

    private func optionRow(title: String, isSelected: Bool, indent: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            checkRowContent(title: title, isSelected: isSelected, indent: indent)
        }
        .buttonStyle(.plain)
    }

    private func checkRowContent(title: String, isSelected: Bool, isMixed: Bool = false, indent: CGFloat = 0) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                checkbox(isSelected: isSelected, isMixed: isMixed)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected || isMixed ? Color.white : Color(white: 0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, indent)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Color(white: isSelected || isMixed ? 0.10 : 0.06))
    }

    private func checkbox(isSelected: Bool, isMixed: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected || isMixed ? Color.white : Color.clear)
                .frame(width: 13, height: 13)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.38), lineWidth: isSelected || isMixed ? 0 : 1))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black)
            } else if isMixed {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 7, height: 1.5)
            }
        }
    }

    private func hasValues(for dimension: FilterDimension) -> Bool {
        switch dimension {
        case .hostname: !uniqueHostnames.isEmpty
        case .source: !uniqueSources.isEmpty
        case .model: !uniqueModels.isEmpty
        case .project: !uniqueProjects.isEmpty
        }
    }

    private func selectedValues(for dimension: FilterDimension) -> Set<String> {
        switch dimension {
        case .hostname: appState.filters.hostnames
        case .source: appState.filters.sources
        case .model: appState.filters.models
        case .project: appState.filters.projects
        }
    }

    private func summaryText(for dimension: FilterDimension) -> String {
        let selectedCount = selectedValues(for: dimension).count
        return selectedCount == 0 ? "全部" : "\(selectedCount) 项"
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if set.contains(value) {
                set.remove(value)
            } else {
                set.insert(value)
            }
        }
    }

    private func displayLabel(for range: TimeRange) -> String {
        switch range {
        case .today: return "今天"
        case .oneDay: return "24H"
        case .custom: return "自定义"
        default: return range.rawValue
        }
    }
}

/// Simple flow layout that wraps items to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
