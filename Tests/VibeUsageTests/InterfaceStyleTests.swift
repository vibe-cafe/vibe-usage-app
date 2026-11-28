import Foundation
import Observation
import Testing
@testable import VibeUsage

@MainActor
struct InterfaceStyleTests {
    /// A domain in a temporary folder (`TestPreferences`, issue #126).
    private func withPreferences(_ run: (String, UserDefaults) -> Void) {
        let domain = TestPreferences.makeDomain("InterfaceStyleTests")
        let defaults = UserDefaults(suiteName: domain)!
        defer { TestPreferences.remove(domain) }
        run(domain, defaults)
    }

    @Test
    func firstLaunchKeepsModernAfterStartupWritesOldAppKeys() {
        withPreferences { domain, defaults in
            let first = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(first.current == .modern)
            #expect(first.canSelect)

            defaults.set(true, forKey: "showCostInMenuBar")
            defaults.set(true, forKey: "quotaSelectionInitialized")
            let next = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(next.current == .modern)
        }
    }

    @Test(arguments: ["showTokensInMenuBar", "claudeRateLimitEnabled", "quotaSelectionInitialized", "selectedQuotaProductIds"])
    func existingInstallKeepsClassicEvenIfUnlinkedOrAllQuotasAreOff(key: String) {
        withPreferences { domain, defaults in
            if key == "selectedQuotaProductIds" {
                defaults.set([String](), forKey: key)
            } else {
                defaults.set(false, forKey: key)
            }
            #expect(InterfaceStylePreference(domain: domain, rollout: .released).current == .classic)
            defaults.removeObject(forKey: key)
            #expect(InterfaceStylePreference(domain: domain, rollout: .released).current == .classic)
        }
    }

    @Test
    func closedRolloutAlwaysUsesClassicAndLeavesPreferencesUntouched() {
        withPreferences { domain, defaults in
            for stored in [nil, "modern"] as [String?] {
                defaults.set(stored, forKey: "interfaceStyle")
                let before = defaults.persistentDomain(forName: domain) as NSDictionary?
                let preference = InterfaceStylePreference(domain: domain, rollout: .unreleased)
                preference.select(.modern)
                #expect(preference.current == .classic)
                #expect(!preference.canSelect)
                #expect(defaults.persistentDomain(forName: domain) as NSDictionary? == before)
            }
        }
    }

    @Test
    func externalTestDefaultsToModernEvenAfterUsingAnOlderTestBuild() {
        withPreferences { domain, defaults in
            defaults.set(true, forKey: "showInDock")
            let preference = InterfaceStylePreference(domain: domain, rollout: .externalTest)
            #expect(preference.current == .modern)
            #expect(preference.canSelect)
            preference.select(.classic)
            #expect(InterfaceStylePreference(domain: domain, rollout: .externalTest).current == .classic)
        }
    }

    @Test
    func cliOnlyInstallStartsModernAndObserversSeeManualSelection() async {
        await confirmation { styleChanged in
            withPreferences { domain, defaults in
                defaults.set("en", forKey: "AppleLocale")
                let state = AppState(
                    initialConfig: VibeUsageConfig(apiKey: "fixture-cli-key"),
                    quotaDefaults: defaults,
                    interfaceStyle: InterfaceStylePreference(domain: domain, rollout: .released)
                )
                #expect(state.interfaceStyle.current == .modern)
                withObservationTracking {
                    _ = state.interfaceStyle.current
                } onChange: {
                    styleChanged()
                }
                state.interfaceStyle.select(.classic)
                #expect(state.interfaceStyle.current == .classic)
                #expect(InterfaceStylePreference(domain: domain, rollout: .released).current == .classic)
            }
        }
    }

    @Test
    func upgradeCanSwitchToModernAndRetainsItsClassicCardPreferences() {
        withPreferences { domain, defaults in
            defaults.set(["codex", "cursor"], forKey: "selectedQuotaProductIds")
            defaults.set(["cursor", "codex"], forKey: "quotaProductOrder")
            defaults.set("cursor", forKey: "quotaSelectedTabId")
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(preference.current == .classic)
            preference.select(.modern)
            #expect(InterfaceStylePreference(domain: domain, rollout: .released).current == .modern)
            #expect(defaults.stringArray(forKey: "selectedQuotaProductIds") == ["codex", "cursor"])
            #expect(defaults.stringArray(forKey: "quotaProductOrder") == ["cursor", "codex"])
            #expect(defaults.string(forKey: "quotaSelectedTabId") == "cursor")
        }
    }

    #if DEBUG
    @Test(arguments: ["modern", "classic"])
    func debugOverrideSwitchesInMemoryWithoutReplacingTheSavedChoice(raw: String) throws {
        let opposite: InterfaceStyle = raw == "modern" ? .classic : .modern
        let forced = try #require(InterfaceStylePreference.Rollout.debugOverride(
            environment: ["VIBE_USAGE_FORCE_INTERFACE_STYLE": raw]
        ))
        withPreferences { domain, defaults in
            defaults.set(opposite.rawValue, forKey: "interfaceStyle")
            let preview = InterfaceStylePreference(domain: domain, rollout: forced)
            #expect(preview.current.rawValue == raw)
            #expect(preview.canSelect)
            preview.select(opposite)
            #expect(preview.current == opposite)
            #expect(InterfaceStylePreference(domain: domain, rollout: .released).current == opposite)
        }
    }

    @Test
    func testsThatNameNoRolloutKeepTheClosedOne() {
        // Most tests build `AppState()` with the shared preference; they must
        // not depend on what earlier runs left in the runner's preferences.
        #expect(InterfaceStylePreference.Rollout.isTestProcess)
        #expect(InterfaceStylePreference.Rollout.current == .unreleased)
    }
    #else
    @Test
    func distributionBuildUsesItsOwnRollout() {
        // Both distribution builds are open: a fresh domain starts modern.
        withPreferences { domain, _ in
            let preference = InterfaceStylePreference(domain: domain)
            #expect(preference.current == .modern)
            #expect(preference.canSelect)
            #expect(!preference.showsClassicReminder)
        }
    }
    #endif

    // MARK: - The two one-time banners (#113)

    /// An install that used a pre-style version (any of its keys), so the
    /// first judgment keeps it on classic.
    private func upgrade(_ defaults: UserDefaults) {
        defaults.set(true, forKey: "showInDock")
    }

    @Test
    func upgradeShowsTheClassicBannerUntilAnsweredAcrossRelaunches() {
        withPreferences { domain, defaults in
            upgrade(defaults)
            let first = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(first.current == .classic)
            #expect(first.showsClassicReminder)
            #expect(!first.showsSwitchBackReminder)
            // Closing the panel without an answer changes nothing; the next
            // launch reads the banner back.
            let relaunched = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(relaunched.current == .classic)
            #expect(relaunched.showsClassicReminder)
        }
    }

    @Test
    func freshInstallAndExternalTestNeverSeeTheClassicBanner() {
        withPreferences { domain, _ in
            let fresh = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(fresh.current == .modern)
            #expect(!fresh.showsClassicReminder)
            #expect(!fresh.showsSwitchBackReminder)
            fresh.select(.classic)
            #expect(!fresh.showsClassicReminder)
            #expect(!InterfaceStylePreference(domain: domain, rollout: .released).showsClassicReminder)
        }
        withPreferences { domain, defaults in
            upgrade(defaults)
            let external = InterfaceStylePreference(domain: domain, rollout: .externalTest)
            #expect(external.current == .modern)
            external.select(.classic)
            #expect(!external.showsClassicReminder)
            #expect(!external.showsSwitchBackReminder)
        }
    }

    @Test
    func notNowEndsTheClassicBannerForGood() {
        withPreferences { domain, defaults in
            upgrade(defaults)
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            preference.dismissClassicReminder()
            #expect(preference.current == .classic)
            #expect(!preference.showsClassicReminder)
            #expect(!preference.showsSwitchBackReminder)
            #expect(defaults.object(forKey: InterfaceStylePreference.classicReminderKey) == nil)

            let relaunched = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(!relaunched.showsClassicReminder)
            relaunched.select(.modern)
            #expect(!relaunched.showsSwitchBackReminder)
            relaunched.select(.classic)
            #expect(!relaunched.showsClassicReminder)
        }
    }

    @Test
    func switchToModernShowsTheSwitchBackBannerUntilClosed() {
        withPreferences { domain, defaults in
            upgrade(defaults)
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            preference.acceptClassicReminder()
            #expect(preference.current == .modern)
            #expect(!preference.showsClassicReminder)
            #expect(preference.showsSwitchBackReminder)

            let relaunched = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(relaunched.current == .modern)
            #expect(relaunched.showsSwitchBackReminder)
            // × and the path to Settings both end it.
            relaunched.dismissSwitchBackReminder()
            #expect(!relaunched.showsSwitchBackReminder)
            #expect(defaults.object(forKey: InterfaceStylePreference.switchBackReminderKey) == nil)
            #expect(!InterfaceStylePreference(domain: domain, rollout: .released).showsSwitchBackReminder)
        }
    }

    @Test
    func switchingTheStyleInSettingsEndsBothBanners() {
        // Before the classic banner was answered.
        withPreferences { domain, defaults in
            upgrade(defaults)
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            preference.select(.modern)
            #expect(!preference.showsSwitchBackReminder)
            preference.select(.classic)
            #expect(!preference.showsClassicReminder)
        }
        // While the switch-back banner shows.
        withPreferences { domain, defaults in
            upgrade(defaults)
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            preference.acceptClassicReminder()
            preference.select(.classic)
            #expect(!preference.showsClassicReminder)
            preference.select(.modern)
            #expect(!preference.showsSwitchBackReminder)
            let relaunched = InterfaceStylePreference(domain: domain, rollout: .released)
            #expect(!relaunched.showsClassicReminder)
            #expect(!relaunched.showsSwitchBackReminder)
        }
    }

    @Test
    func choosingTheCurrentStyleAgainKeepsTheBanner() {
        // The segmented control sends its current value again on a click.
        withPreferences { domain, defaults in
            upgrade(defaults)
            let preference = InterfaceStylePreference(domain: domain, rollout: .released)
            preference.select(.classic)
            #expect(preference.showsClassicReminder)
        }
    }

    @Test
    func closedRolloutNeverShowsOrWritesABanner() {
        withPreferences { domain, defaults in
            upgrade(defaults)
            let before = defaults.persistentDomain(forName: domain) as NSDictionary?
            let preference = InterfaceStylePreference(domain: domain, rollout: .unreleased)
            #expect(!preference.showsClassicReminder)
            preference.acceptClassicReminder()
            preference.dismissClassicReminder()
            preference.dismissSwitchBackReminder()
            #expect(preference.current == .classic)
            #expect(!preference.showsSwitchBackReminder)
            #expect(defaults.persistentDomain(forName: domain) as NSDictionary? == before)
        }
    }

    @Test
    func switchToModernFromTheBannerPutsThePeriodOnTheNewPanelsDefault() {
        withPreferences { domain, defaults in
            upgrade(defaults)
            let state = AppState(
                loadConfig: { nil },
                usageFetcher: { _, _, _ in throw URLError(.notConnectedToInternet) },
                activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) },
                quotaDefaults: defaults,
                interfaceStyle: InterfaceStylePreference(domain: domain, rollout: .released)
            )
            state.applyDefaultTimeRangeForInterfaceStyle()
            #expect(state.timeRange == .oneDay)
            #expect(state.interfaceStyle.showsClassicReminder)

            state.acceptClassicStyleReminder()
            #expect(state.interfaceStyle.current == .modern)
            #expect(state.timeRange == .today)
            #expect(state.interfaceStyle.showsSwitchBackReminder)

            state.selectInterfaceStyle(.classic)
            #expect(state.timeRange == .oneDay)
            #expect(!state.interfaceStyle.showsClassicReminder)
            #expect(!state.interfaceStyle.showsSwitchBackReminder)
        }
    }
}
