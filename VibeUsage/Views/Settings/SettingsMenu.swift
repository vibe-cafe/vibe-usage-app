import SwiftUI

/// The modern style's pop-up menu (design §10 #15, drawing 140m): the
/// panel's menu — a raised card, one row per option, a small lamp lit before
/// the chosen one. Classic keeps the system pop-up button.
///
/// The menu is drawn by the window's root overlay (`SettingsMenuOverlay`),
/// not next to its button: pages scroll and cards clip, and the menu must
/// hang over both. The button publishes what to show; the overlay places it
/// under the button (above it when the window is too short) and closes it on
/// a click outside, Escape, a choice, or when the button moves (the page
/// scrolled). One menu per window.
@MainActor
@Observable
final class SettingsMenuState {
    nonisolated static let space = "settingsWindow"

    struct Request {
        let id: String
        /// The button's frame in `space`.
        let anchor: CGRect
        let titles: [String]
        let selected: Int
        let choose: @MainActor (Int) -> Void
    }

    private(set) var request: Request?
    /// Off-screen renders: the button with this id opens itself once laid out.
    @ObservationIgnored var opensOnLayout: String?

    init(opensOnLayout: String? = nil) {
        self.opensOnLayout = opensOnLayout
    }

    func open(_ request: Request) { self.request = request }
    func close() { request = nil }
}

/// The button: the panel's 24 pt pill with the current choice and a small
/// chevron. VoiceOver gets a standard picker.
struct SettingsMenuPicker<Value: Hashable>: View {
    let id: String
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(SettingsMenuState.self) private var menu
    @Environment(\.settingsTheme) private var theme
    @State private var frame: CGRect = .zero

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Text(options[selectedIndex].title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .buttonStyle(.settings)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SettingsMenuState.space)) } action: { newFrame in
            if menu.request?.id == id, newFrame != frame { menu.close() }
            frame = newFrame
            if menu.opensOnLayout == id {
                menu.opensOnLayout = nil
                open()
            }
        }
        .onDisappear {
            if menu.request?.id == id { menu.close() }
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
        }
    }

    private func toggle() {
        if menu.request?.id == id { menu.close() } else { open() }
    }

    private func open() {
        let options = options
        let binding = $selection
        menu.open(.init(
            id: id, anchor: frame, titles: options.map(\.title), selected: selectedIndex,
            choose: { binding.wrappedValue = options[$0].value }
        ))
    }
}

/// Where the open menu goes: under its button, right edges aligned, 4 pt
/// below (28 from the button's top, as drawn); above the button when it
/// would leave the window; never closer than 8 pt to a window edge.
enum SettingsMenuPlacement {
    static let width: CGFloat = 172
    static let padding: CGFloat = 6
    static let rowHeight: CGFloat = 26
    static let gap: CGFloat = 4
    static let edgeInset: CGFloat = 8

    static func size(rows: Int) -> CGSize {
        CGSize(width: width, height: padding * 2 + rowHeight * CGFloat(rows))
    }

    static func origin(anchor: CGRect, menuSize: CGSize, container: CGSize) -> CGPoint {
        var x = anchor.maxX - menuSize.width
        x = min(max(x, edgeInset), container.width - edgeInset - menuSize.width)
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - menuSize.height
        let y = below + menuSize.height <= container.height - edgeInset || above < edgeInset ? below : above
        return CGPoint(x: x, y: y)
    }
}

/// The window-level layer that draws the open menu.
struct SettingsMenuOverlay: View {
    @Environment(SettingsMenuState.self) private var menu

    var body: some View {
        if let request = menu.request {
            GeometryReader { proxy in
                let size = SettingsMenuPlacement.size(rows: request.titles.count)
                let origin = SettingsMenuPlacement.origin(anchor: request.anchor, menuSize: size, container: proxy.size)
                ZStack(alignment: .topLeading) {
                    // A click anywhere else only closes the menu, like a menu.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { menu.close() }
                    SettingsMenuList(request: request) { menu.close() }
                        .frame(width: size.width, height: size.height)
                        .offset(x: origin.x, y: origin.y)
                }
            }
            // Same origin as `space` (the whole window, title bar included).
            .ignoresSafeArea()
        }
    }
}

private struct SettingsMenuList: View {
    let request: SettingsMenuState.Request
    let dismiss: @MainActor () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(request.titles.enumerated()), id: \.offset) { index, title in
                row(index: index, title: title)
            }
        }
        .padding(SettingsMenuPlacement.padding)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape
                .fill(LinearGradient(
                    colors: [theme.raised, Color(settingsHex: 0x22262B)], startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        .mask(LinearGradient(
                            stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.08)],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
                .overlay { shape.inset(by: -1).strokeBorder(Color.black.opacity(0.45), lineWidth: 1) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            choose(highlighted ?? request.selected)
            return .handled
        }
        .accessibilityHidden(true)
    }

    private func row(index: Int, title: String) -> some View {
        let isOn = index == request.selected
        return HStack(spacing: 8) {
            Lamp(isOn: isOn)
            Text(title)
                .font(SettingsFont.text(13, isOn ? .medium : .regular))
                .foregroundStyle(isOn ? theme.text : theme.text.opacity(0.86))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: SettingsMenuPlacement.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted == index ? theme.selection : .clear)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .onTapGesture { choose(index) }
    }

    private func move(_ step: Int) {
        let count = request.titles.count
        let current = highlighted ?? request.selected
        highlighted = (current + step + count) % count
    }

    private func choose(_ index: Int) {
        request.choose(index)
        dismiss()
    }

    /// The panel's small lamp: a dark well, lit when chosen.
    private struct Lamp: View {
        let isOn: Bool

        var body: some View {
            Circle()
                .fill(Color(settingsHex: 0x0D1013))
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.8), lineWidth: 1)
                        .blur(radius: 1)
                        .offset(y: 1)
                        .clipShape(Circle())
                }
                .overlay {
                    Circle()
                        .fill(isOn ? Color(settingsHex: 0xEEF0F2) : Color(settingsHex: 0x2B3036))
                        .shadow(color: isOn ? Color(settingsHex: 0xE7EBEE).opacity(0.75) : .clear, radius: 2.5)
                        .shadow(color: isOn ? .white.opacity(0.9) : .clear, radius: 0.5)
                        .frame(width: 6, height: 6)
                }
                .frame(width: 12, height: 12)
        }
    }
}
