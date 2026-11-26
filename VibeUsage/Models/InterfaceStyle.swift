import Foundation
import Observation

enum InterfaceStyle: String {
    case modern
    case classic

    var displayName: String {
        switch self {
        case .modern: "新版"
        case .classic: "经典"
        }
    }
}

@Observable
@MainActor
final class InterfaceStylePreference {
    enum Rollout: Equatable {
        case unreleased
        case externalTest
        case released

        #if DEBUG
        case forced(InterfaceStyle)

        static func debugOverride(environment: [String: String]) -> Self? {
            environment["VIBE_USAGE_FORCE_INTERFACE_STYLE"]
                .flatMap(InterfaceStyle.init(rawValue:)).map(Self.forced)
        }
        #endif

        static var current: Self {
            #if DEBUG
            if let override = debugOverride(environment: ProcessInfo.processInfo.environment) {
                return override
            }
            #endif
            if AppConfig.isExternalTest { return .externalTest }
            return AppConfig.interfaceStyleReleased ? .released : .unreleased
        }
    }

    private static let key = "interfaceStyle"
    // Keys written by pre-style versions of the Mac app. AppKit, Sparkle and
    // registered defaults are not evidence that the user saw the old panel.
    private static let legacyKeys: Set<String> = [
        "showCostInMenuBar", "showTokensInMenuBar", "showInDock", "showProjects",
        "rateLimitMonitoringEnabled", "codexRateLimitEnabled", "claudeRateLimitEnabled",
        "claudeRateLimitHasSucceeded", "claudeRateLimitProbeMigrationDone",
        "quotaSelectionInitialized", "selectedQuotaProductIds", "quotaProductOrder", "quotaSelectedTabId",
        "settingsLastPage", "diagnosticsSyncHistory.v1", "zCodeQuotaRegion", "cliRuntimePreference",
        "egressMode", "egressCheckEnabled", "egressRequireLocalProxy",
    ]
    private let defaults: UserDefaults?
    private(set) var current: InterfaceStyle
    var canSelect: Bool { defaults != nil }

    init(domain: String? = nil, rollout: Rollout = .current) {
        switch rollout {
        case .unreleased:
            defaults = nil
            current = .classic
            return
        #if DEBUG
        case .forced(let style):
            defaults = nil
            current = style
            return
        #endif
        case .externalTest, .released:
            break
        }

        let defaults = domain.map { UserDefaults(suiteName: $0)! } ?? .standard
        self.defaults = defaults
        let domainName = domain ?? Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = defaults.persistentDomain(forName: domainName) ?? [:]
        if let value = stored[Self.key] as? String, let style = InterfaceStyle(rawValue: value) {
            current = style
        } else {
            let isUpgrade = rollout == .released && !Self.legacyKeys.isDisjoint(with: stored.keys)
            current = isUpgrade ? .classic : .modern
            defaults.set(current.rawValue, forKey: Self.key)
        }
    }

    func select(_ style: InterfaceStyle) {
        guard let defaults else { return }
        defaults.set(style.rawValue, forKey: Self.key)
        current = style
    }
}
