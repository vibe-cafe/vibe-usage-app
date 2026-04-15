import AppKit
import SwiftUI
import Observation

/// SwiftUI view rendered inside the NSStatusItem button.
/// Using NSHostingView for the status item content is the best-practice workaround
/// for proper vertical centering of multi-line text — attributedTitle and
/// hand-composed NSImages both fight the menu-bar's implicit vertical metrics.
private struct MenuBarLabel: View {
    let icon: NSImage
    let lines: [String]

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: icon)
                .renderingMode(.template)

            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: lines.count > 1 ? -2 : 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: lines.count == 1 ? 13 : 10, weight: .medium, design: .monospaced))
                    }
                }
                .fixedSize()
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 4)
        .fixedSize()
    }
}

/// NSHostingView subclass that passes mouse events through to its superview.
/// Required when hosting SwiftUI inside an NSStatusBarButton — the default
/// NSHostingView consumes hit-tests, which swallows the button's click action
/// and the popover never opens.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns the menu-bar status item and the borderless popover panel.
/// Replaces SwiftUI MenuBarExtra so we can:
///   - render stacked text (cost over tokens) via NSHostingView
///   - control the popover open/close animation (anchored to the icon)
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let updaterViewModel: UpdaterViewModel

    private let statusItem: NSStatusItem
    private var hostingView: PassThroughHostingView<MenuBarLabel>!
    private var panel: PopoverPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var isAnimating = false

    private static let panelWidth: CGFloat = 520
    private static let panelTopGap: CGFloat = 6
    private static let openDuration: CFTimeInterval = 0.22
    private static let closeDuration: CFTimeInterval = 0.14
    private static let openScale: CGFloat = 0.9
    private static let closeScale: CGFloat = 0.94
    /// Initial downward offset (in layer coords, positive = up in unflipped NSView).
    /// Creates a "falling out of the menu bar" feel when combined with scale.
    private static let openYOffset: CGFloat = 4

    init(appState: AppState, updaterViewModel: UpdaterViewModel) {
        self.appState = appState
        self.updaterViewModel = updaterViewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        observeStateChanges()

        // Popup sits at .popUpMenu level (above everything) normally. Lower to
        // .normal while Settings is visible so clicking/dragging Settings can
        // bring it to the front through standard z-ordering.
        ActivationCoordinator.shared.onSettingsVisibilityChange = { [weak self] visible in
            self?.panel?.level = visible ? .normal : .popUpMenu
        }
    }

    // MARK: - Status item

    private static let iconSize = NSSize(width: 18, height: 18)

    /// Raw icon (template) used as the SwiftUI status-item label.
    private static let iconRaw: NSImage = {
        if let url = Bundle.appResources.url(forResource: "menubar-icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = iconSize
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)!
        fallback.size = iconSize
        fallback.isTemplate = true
        return fallback
    }()

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        // Clear the native button content — we draw everything via NSHostingView.
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(handleClick(_:))

        let host = PassThroughHostingView(rootView: MenuBarLabel(icon: Self.iconRaw, lines: []))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        self.hostingView = host
    }

    /// Tracks AppState reads inside `refreshStatusItem`; re-fires on any change,
    /// then re-registers (Observation only fires once per registration).
    private func observeStateChanges() {
        withObservationTracking {
            refreshStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStateChanges() }
        }
    }

    private func refreshStatusItem() {
        guard hostingView != nil else { return }
        let lines = menuBarLines()
        hostingView.rootView = MenuBarLabel(icon: Self.iconRaw, lines: lines)
        // Force SwiftUI layout so fittingSize is current, then size the status item accordingly.
        hostingView.layoutSubtreeIfNeeded()
        let width = hostingView.fittingSize.width
        statusItem.length = width > 0 ? width : NSStatusItem.variableLength
    }

    private func menuBarLines() -> [String] {
        guard appState.isConfigured, !appState.buckets.isEmpty else { return [] }
        var lines: [String] = []
        if appState.showCostInMenuBar {
            lines.append(Formatters.formatCost(appState.menuBarCost))
        }
        if appState.showTokensInMenuBar {
            lines.append(Formatters.formatNumber(appState.menuBarTokens))
        }
        return lines
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Panel lifecycle

    private func openPanel() {
        guard !isAnimating else { return }

        let panel = ensurePanel()
        positionPanel(panel)

        Task { await appState.fetchUsageDataIfNeeded() }

        // Bump activation policy so TextFields (unconfigured screen) receive keys.
        // ActivationCoordinator reconciles .regular/.accessory/.prohibited based
        // on whether Settings is also visible — avoids clobbering Settings state.
        ActivationCoordinator.shared.popupDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        animateOpen(panel)
        installEventMonitors()
    }

    private func closePanel() {
        guard let panel, panel.isVisible, !isAnimating else { return }
        animateClose(panel) { [weak self] in
            panel.orderOut(nil)
            ActivationCoordinator.shared.popupDidClose()
            self?.removeEventMonitors()
        }
    }

    private func ensurePanel() -> PopoverPanel {
        if let panel { return panel }

        let rootView = AnyView(
            PopoverView()
                .environment(appState)
                .environmentObject(updaterViewModel)
        )
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        hostingController = host

        let panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 620),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Rounded corners on the hosting view's layer so the SwiftUI background gets clipped.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
        }

        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: PopoverPanel) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame

        // Use the constant width — on first open SwiftUI hasn't laid out yet so
        // panel.frame.size.width can be 0/stale, which sends the right-aligned
        // anchor off-screen.
        let width = Self.panelWidth

        // Anchor the panel's right edge to the icon's right edge so a far-right icon
        // doesn't push the panel off-screen. Use setFrameTopLeftPoint so we don't
        // depend on the (possibly stale) height for the Y calculation.
        var topLeftX = buttonFrame.maxX - width
        let topLeftY = buttonFrame.minY - Self.panelTopGap

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonFrame.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            topLeftX = max(visible.minX + 8, min(topLeftX, visible.maxX - width - 8))
        }
        panel.setFrameTopLeftPoint(NSPoint(x: topLeftX, y: topLeftY))
    }

    // MARK: - Animation

    /// Combined scale + Y-translation transform, so the panel appears to "fall out"
    /// of the menu-bar icon (icon sits at the panel's top-right).
    private static func popTransform(scale: CGFloat, yOffset: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, 0, yOffset, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return t
    }

    // Snappy ease-out (mimics Apple's "easeOutQuint") — content moves fast at the start,
    // decelerates smoothly at the end. Matches Apple-native popover feel without bounce.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    private static let easeIn = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.4)

    private func animateOpen(_ panel: PopoverPanel) {
        guard let layer = panel.contentView?.layer else { return }
        isAnimating = true

        // Anchor at top-right so scale and translation both appear to originate at
        // the menu-bar icon (the panel is right-aligned to the icon).
        setAnchorPoint(CGPoint(x: 1.0, y: 1.0), for: layer)

        let startTransform = Self.popTransform(scale: Self.openScale, yOffset: Self.openYOffset)

        layer.opacity = 0
        layer.transform = startTransform

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.isAnimating = false
        }

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: startTransform)
        transformAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformAnim.duration = Self.openDuration
        transformAnim.timingFunction = Self.easeOut
        layer.add(transformAnim, forKey: "openTransform")

        // Fade shorter than transform so content becomes readable before settle.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.openDuration * 0.7
        fade.timingFunction = Self.easeOut
        layer.add(fade, forKey: "openFade")

        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        // Panel alphaValue drives the window shadow — match the content fade so the
        // shadow doesn't linger a frame ahead of the visible card.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.openDuration * 0.7
            ctx.timingFunction = Self.easeOut
            panel.animator().alphaValue = 1
        }
    }

    private func animateClose(_ panel: PopoverPanel, completion: @escaping () -> Void) {
        guard let layer = panel.contentView?.layer else {
            completion()
            return
        }
        isAnimating = true

        let endTransform = Self.popTransform(scale: Self.closeScale, yOffset: Self.openYOffset * 0.6)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.isAnimating = false
            completion()
        }

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformAnim.toValue = NSValue(caTransform3D: endTransform)
        transformAnim.duration = Self.closeDuration
        transformAnim.timingFunction = Self.easeIn
        layer.add(transformAnim, forKey: "closeTransform")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.closeDuration
        fade.timingFunction = Self.easeIn
        layer.add(fade, forKey: "closeFade")

        layer.opacity = 0
        layer.transform = endTransform
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.closeDuration
            ctx.timingFunction = Self.easeIn
            panel.animator().alphaValue = 0
        }
    }

    /// Adjust a layer's anchor point without visually shifting it.
    private func setAnchorPoint(_ anchor: CGPoint, for layer: CALayer) {
        let oldAnchor = layer.anchorPoint
        let bounds = layer.bounds

        let newPoint = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        let oldPoint = CGPoint(x: bounds.width * oldAnchor.x, y: bounds.height * oldAnchor.y)
        let position = layer.position
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: position.x - oldPoint.x + newPoint.x,
                                  y: position.y - oldPoint.y + newPoint.y)
    }

    // MARK: - Outside-click & ESC dismissal

    private func installEventMonitors() {
        removeEventMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Ignore clicks on our own status-bar button — `button.action` runs on
                // mouse-up and will toggle the panel itself. If we close here on
                // mouse-down, the subsequent mouse-up reopens it.
                if let buttonFrame = self.statusItem.button?.window?.frame,
                   buttonFrame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.closePanel()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // ESC = 53
            if event.keyCode == 53 {
                Task { @MainActor in self?.closePanel() }
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) }
        globalEventMonitor = nil
        localEventMonitor = nil
    }
}
