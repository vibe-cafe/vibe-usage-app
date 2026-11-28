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
    static let shared = InterfaceStylePreference()

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

        /// XCTest is loaded by every test runner (`swift test`, Xcode),
        /// never by the app.
        static var isTestProcess: Bool {
            NSClassFromString("XCTestCase") != nil
        }
        #endif

        static var current: Self {
            #if DEBUG
            if let override = debugOverride(environment: ProcessInfo.processInfo.environment) {
                return override
            }
            // A test that names no rollout (most build `AppState()` with the
            // shared preference) keeps the classic panel and leaves the test
            // runner's own preferences alone, whatever earlier runs left
            // there; tests of the rollout pass one explicitly.
            if isTestProcess { return .unreleased }
            #endif
            if AppConfig.isExternalTest { return .externalTest }
            return AppConfig.interfaceStyleReleased ? .released : .unreleased
        }
    }

    private static let key = "interfaceStyle"
    /// Set when the first judgment keeps an upgraded user on classic; removed
    /// once that user answers the classic panel's banner or switches the
    /// style in Settings. Absent means the banner never shows again.
    static let classicReminderKey = "interfaceStyleClassicReminderPending"
    /// Set by the classic banner's 「切换新版」; removed by the new panel's
    /// ×, its path to Settings, or a style switch in Settings.
    static let switchBackReminderKey = "interfaceStyleSwitchBackReminderPending"
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
    /// A forced (Debug) style can still be switched in memory, so renders and
    /// manual checks see the settings row; nothing is written to preferences.
    private var switchesInMemory = false
    private(set) var current: InterfaceStyle
    var canSelect: Bool { defaults != nil || switchesInMemory }
    private var classicReminderPending = false
    private var switchBackReminderPending = false

    /// The classic panel's one-time banner (「切换新版」 / 「先不用」): an
    /// upgraded user on classic who has not answered it or switched the style.
    var showsClassicReminder: Bool { current == .classic && classicReminderPending }
    /// The new panel's banner on how to switch back, after 「切换新版」.
    var showsSwitchBackReminder: Bool { current == .modern && switchBackReminderPending }

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
            switchesInMemory = true
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
            classicReminderPending = stored[Self.classicReminderKey] as? Bool ?? false
            switchBackReminderPending = stored[Self.switchBackReminderKey] as? Bool ?? false
        } else {
            let isUpgrade = rollout == .released && !Self.legacyKeys.isDisjoint(with: stored.keys)
            current = isUpgrade ? .classic : .modern
            defaults.set(current.rawValue, forKey: Self.key)
            // Only an upgrade kept on classic is told about the new panel.
            if isUpgrade {
                classicReminderPending = true
                defaults.set(true, forKey: Self.classicReminderKey)
            }
        }
    }

    /// 「界面样式」 in Settings. A real switch ends both reminders for good:
    /// the user has found the setting.
    func select(_ style: InterfaceStyle) {
        guard canSelect else { return }
        let changed = style != current
        defaults?.set(style.rawValue, forKey: Self.key)
        current = style
        if changed {
            setClassicReminder(false)
            setSwitchBackReminder(false)
        }
    }

    /// The classic banner's 「先不用」.
    func dismissClassicReminder() {
        setClassicReminder(false)
    }

    /// The classic banner's 「切换新版」: the new panel, which then says once
    /// where to switch back.
    func acceptClassicReminder() {
        guard canSelect else { return }
        defaults?.set(InterfaceStyle.modern.rawValue, forKey: Self.key)
        current = .modern
        setClassicReminder(false)
        setSwitchBackReminder(true)
    }

    /// The switch-back banner's × or its path to Settings.
    func dismissSwitchBackReminder() {
        setSwitchBackReminder(false)
    }

    // A forced (Debug) style has no preferences and never shows a reminder.
    private func setClassicReminder(_ pending: Bool) {
        guard let defaults else { return }
        classicReminderPending = pending
        if pending {
            defaults.set(true, forKey: Self.classicReminderKey)
        } else {
            defaults.removeObject(forKey: Self.classicReminderKey)
        }
    }

    private func setSwitchBackReminder(_ pending: Bool) {
        guard let defaults else { return }
        switchBackReminderPending = pending
        if pending {
            defaults.set(true, forKey: Self.switchBackReminderKey)
        } else {
            defaults.removeObject(forKey: Self.switchBackReminderKey)
        }
    }
}
