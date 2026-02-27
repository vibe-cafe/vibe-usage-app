import SwiftUI
import AppKit

@main
struct VibeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @StateObject private var updaterViewModel = UpdaterViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appState)
                .environmentObject(updaterViewModel)
        } label: {
            // MenuBarExtra label ignores HStack spacing / padding.
            // Must use NSImage with explicit size for custom icons.
            let icon: NSImage = {
                if let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    let ratio = img.size.height / img.size.width
                    img.size.height = 18
                    img.size.width = 18 / ratio
                    img.isTemplate = true
                    return img
                }
                return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)!
            }()

            if appState.isConfigured && !appState.buckets.isEmpty,
               !menuBarText.isEmpty {
                // Use Text with icon character + spacing for gap control
                Image(nsImage: icon)
                Text("  " + menuBarText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            } else {
                Image(nsImage: icon)
            }
        }
        .menuBarExtraStyle(.window)

        // Settings managed by SettingsWindowController (NSWindow)
        // Settings managed by SettingsWindowController (NSWindow)
        // SwiftUI Window/Settings scenes don't work in LSUIElement menu bar apps
    }

    init() {
        appState.initialize()
        HookManager.writeMarker()
        HookManager.removeHooks()
    }

    private var menuBarText: String {
        var parts: [String] = []
        if appState.showCostInMenuBar {
            parts.append(Formatters.formatCost(appState.menuBarCost))
        }
        if appState.showTokensInMenuBar {
            parts.append("\u{1F143}" + Formatters.formatNumber(appState.menuBarTokens))
        }
        return parts.joined(separator: "  ")
    }
}

/// Handles app termination to restore hooks and clean up marker
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HookManager.restoreHooks()
        HookManager.removeMarker()
    }
}
