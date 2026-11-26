import Foundation
import Observation
import Testing
@testable import VibeUsage

@MainActor
struct InterfaceStyleTests {
    private func withPreferences(_ run: (String, UserDefaults) -> Void) {
        let domain = "InterfaceStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
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
    #else
    @Test
    func distributionBuildUsesItsOwnRollout() {
        withPreferences { domain, _ in
            let preference = InterfaceStylePreference(domain: domain)
            #if VIBE_USAGE_EXTERNAL_TEST
            #expect(preference.current == .modern)
            #expect(preference.canSelect)
            #else
            #expect(preference.current == .classic)
            #expect(!preference.canSelect)
            #endif
        }
    }
    #endif
}
