import SwiftUI

@main
struct VibeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        // Onboarding window — shown only when no API Key configured
        Window("Vibe Usage", id: "onboarding") {
            OnboardingView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 480)
        .windowResizability(.contentSize)

        // Settings managed by SettingsWindowController (NSWindow)
        // SwiftUI Window/Settings scenes don't work in LSUIElement menu bar apps
    }

    init() {
        appState.initialize()
        HookManager.writeMarker()
        HookManager.removeHooks()
    }
}

/// Menu bar label: icon + optional cost/tokens text
struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            MenuBarIcon(state: appState.syncStatus)

            if appState.isConfigured && !appState.buckets.isEmpty {
                let parts = menuBarText
                if !parts.isEmpty {
                    Text(parts)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
    }

    private var menuBarText: String {
        var parts: [String] = []
        if appState.showCostInMenuBar {
            parts.append(Formatters.formatCost(appState.menuBarCost))
        }
        if appState.showTokensInMenuBar {
            parts.append(Formatters.formatNumber(appState.menuBarTokens))
        }
        return parts.joined(separator: " | ")
    }
}

/// Handles app termination to restore hooks and clean up marker
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HookManager.restoreHooks()
        HookManager.removeMarker()
    }
}
