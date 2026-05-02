import SwiftUI

struct FilterTagsView: View {
    @Environment(AppState.self) private var appState
    @State private var showProjects: Bool = UserDefaults.standard.object(forKey: "showProjects") as? Bool ?? false
    @State private var expandedFamilies: Set<String> = Set()

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
            // Date / time range row
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("日期")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 48, alignment: .trailing)
                .padding(.vertical, 3)

                HStack(spacing: 6) {
                    ForEach(TimeRange.allCases, id: \.rawValue) { range in
                        let isActive = state.timeRange == range
                        Button {
                            state.timeRange = range
                            Task {
                                await appState.fetchUsageData()
                            }
                        } label: {
                            Text(range.rawValue)
                                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(isActive ? Color.white : Color(white: 0.16))
                                .foregroundStyle(isActive ? Color.black : Color(white: 0.63))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !uniqueHostnames.isEmpty {
                filterRow(
                    icon: "desktopcomputer",
                    label: "终端",
                    values: uniqueHostnames,
                    selected: state.filters.hostnames
                ) { value in
                    if state.filters.hostnames.contains(value) {
                        state.filters.hostnames.remove(value)
                    } else {
                        state.filters.hostnames.insert(value)
                    }
                }
            }

            if !uniqueSources.isEmpty {
                filterRow(
                    icon: "terminal",
                    label: "工具",
                    values: uniqueSources,
                    selected: state.filters.sources
                ) { value in
                    if state.filters.sources.contains(value) {
                        state.filters.sources.remove(value)
                    } else {
                        state.filters.sources.insert(value)
                    }
                }
            }

            if !uniqueModels.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text("模型")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 48, alignment: .trailing)
                    .padding(.vertical, 3)

                    FlowLayout(spacing: 6) {
                        let groups = groupModelsByFamily(uniqueModels)
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            let familyKey = group.family?.key ?? "other"
                            let familyLabel = group.family?.label ?? "其他"
                            let familyModels = Set(group.models)
                            let selectedInFamily = familyModels.intersection(state.filters.models)
                            let allSelected = selectedInFamily.count == familyModels.count && !familyModels.isEmpty
                            let someSelected = !selectedInFamily.isEmpty && !allSelected
                            let isExpanded = expandedFamilies.contains(familyKey)

                            Button {
                                if allSelected {
                                    state.filters.models.subtract(familyModels)
                                } else {
                                    state.filters.models.formUnion(familyModels)
                                }
                            } label: {
                                Text(familyLabel)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(allSelected ? Color.white : (someSelected ? Color(white: 0.28) : Color(white: 0.16)))
                                    .foregroundStyle(allSelected ? Color.black : (someSelected ? Color.white : Color(white: 0.63)))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            HoverChevronButton(isExpanded: isExpanded) {
                                if isExpanded {
                                    expandedFamilies.remove(familyKey)
                                } else {
                                    expandedFamilies.insert(familyKey)
                                }
                            }

                            if isExpanded {
                                ForEach(group.models, id: \.self) { value in
                                    let isActive = state.filters.models.contains(value)
                                    Button {
                                        if state.filters.models.contains(value) {
                                            state.filters.models.remove(value)
                                        } else {
                                            state.filters.models.insert(value)
                                        }
                                    } label: {
                                        Text(value.isEmpty ? "\u{672A}\u{77E5}" : value)
                                            .font(.system(size: 12))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 3)
                                            .background(isActive ? Color.white : Color(white: 0.16))
                                            .foregroundStyle(isActive ? Color.black : Color(white: 0.63))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            if !uniqueProjects.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("项目")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 48, alignment: .trailing)
                    .padding(.vertical, 3)

                    HStack(spacing: 4) {
                        Button {
                            showProjects.toggle()
                            UserDefaults.standard.set(showProjects, forKey: "showProjects")
                        } label: {
                            Image(systemName: showProjects ? "eye" : "eye.slash")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(white: showProjects ? 0.6 : 0.35))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(white: 0.16))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(showProjects ? "隐藏项目名称" : "显示项目名称")

                        HoverChevronButton(isExpanded: showProjects) {
                            showProjects.toggle()
                            UserDefaults.standard.set(showProjects, forKey: "showProjects")
                        }
                    }

                    if showProjects {
                        FlowLayout(spacing: 6) {
                            ForEach(uniqueProjects, id: \.self) { value in
                                let isActive = state.filters.projects.contains(value)
                                Button {
                                    if state.filters.projects.contains(value) {
                                        state.filters.projects.remove(value)
                                    } else {
                                        state.filters.projects.insert(value)
                                    }
                                } label: {
                                    Text(value.isEmpty ? "未知" : value)
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3)
                                        .background(isActive ? Color.white : Color(white: 0.16))
                                        .foregroundStyle(isActive ? Color.black : Color(white: 0.63))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if !appState.filters.isEmpty {
                Button("清除筛选") {
                    state.filters.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
                .padding(.leading, 56)
            }
        }
    }

    private func filterRow(
        icon: String,
        label: String,
        values: [String],
        selected: Set<String>,
        masked: Bool = false,
        eyeToggle: (() -> Void)? = nil,
        toggle: @escaping (String) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color(white: 0.5))
            .frame(width: 48, alignment: .trailing)
            .padding(.vertical, 3) // match tag vertical padding for baseline alignment

            if let eyeToggle {
                Button {
                    eyeToggle()
                } label: {
                    Image(systemName: masked ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: masked ? 0.35 : 0.6))
                        .frame(height: 12 + 6) // match tag height (font 12 + padding 3*2)
                }
                .buttonStyle(.plain)
                .help(masked ? "\u{663E}\u{793A}\u{9879}\u{76EE}\u{540D}\u{79F0}" : "\u{9690}\u{85CF}\u{9879}\u{76EE}\u{540D}\u{79F0}")
            }

            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    let isActive = selected.contains(value)
                    Button {
                        toggle(value)
                    } label: {
                        Text(masked ? "\u{2022}\u{2022}\u{2022}" : (value.isEmpty ? "\u{672A}\u{77E5}" : value))
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(isActive ? Color.white : Color(white: 0.16))
                            .foregroundStyle(isActive ? Color.black : Color(white: 0.63))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Simple flow layout that wraps items to the next line
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

struct HoverChevronButton: View {
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(isHovered ? Color.white : Color(white: 0.38))
                .frame(height: 18)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
