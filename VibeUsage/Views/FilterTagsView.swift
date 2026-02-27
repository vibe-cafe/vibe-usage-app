import SwiftUI

struct FilterTagsView: View {
    @Environment(AppState.self) private var appState
    @State private var showProjects: Bool = UserDefaults.standard.object(forKey: "showProjects") as? Bool ?? false

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

        VStack(alignment: .leading, spacing: 6) {
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
                filterRow(
                    icon: "cpu",
                    label: "模型",
                    values: uniqueModels,
                    selected: state.filters.models
                ) { value in
                    if state.filters.models.contains(value) {
                        state.filters.models.remove(value)
                    } else {
                        state.filters.models.insert(value)
                    }
                }
            }

            if !uniqueProjects.isEmpty {
                filterRow(
                    icon: "folder",
                    label: "项目",
                    values: uniqueProjects,
                    selected: state.filters.projects,
                    masked: !showProjects,
                    eyeToggle: {
                        showProjects.toggle()
                        UserDefaults.standard.set(showProjects, forKey: "showProjects")
                    }
                ) { value in
                    if state.filters.projects.contains(value) {
                        state.filters.projects.remove(value)
                    } else {
                        state.filters.projects.insert(value)
                    }
                }
            }

            if !appState.filters.isEmpty {
                Button("清除筛选") {
                    state.filters.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.8))
                .padding(.leading, 52)
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
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
                if let eyeToggle {
                    Button {
                        eyeToggle()
                    } label: {
                        Image(systemName: masked ? "eye.slash" : "eye")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: masked ? 0.35 : 0.6))
                    }
                    .buttonStyle(.plain)
                    .help(masked ? "显示项目名称" : "隐藏项目名称")
                }
            }
            .foregroundStyle(Color(white: 0.5))
            .frame(width: 56, alignment: .trailing)

            FlowLayout(spacing: 4) {
                ForEach(values, id: \.self) { value in
                    let isActive = selected.contains(value)
                    Button {
                        toggle(value)
                    } label: {
                        Text(masked ? "•••" : (value.isEmpty ? "未知" : value))
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isActive ? Color.white : Color(white: 0.09))
                            .foregroundStyle(isActive ? Color.black : Color(white: 0.63))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(white: isActive ? 0.0 : 0.16), lineWidth: 1)
                            )
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
