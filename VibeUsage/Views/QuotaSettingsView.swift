import SwiftUI

/// Settings facts per quota product. The sidebar's 提供商 rows and every
/// product page come from the `QuotaProductRegistry` catalog (through
/// `AppState`); the switches below are exhaustive, so a new catalog provider
/// does not compile until it states which page it gets. Adding a provider is
/// therefore one catalog entry, plus a page case only when it has something
/// to configure.
enum QuotaSettingsCatalog {
    /// What a product's detail page holds beyond its status rows.
    enum Page: Equatable {
        case standard
        /// Region picker plus the user-entered key (`ZCodeAPIKeySection`).
        case zCodeAPIKey
    }

    static func page(for provider: ProviderRateLimit.Provider) -> Page {
        switch provider {
        case .zCode:
            return .zCodeAPIKey
        case .codex, .claudeCode, .kimiCode, .grok, .cursor, .opencodeGo, .antigravity:
            return .standard
        }
    }

    /// Where the quota is read from, when that is worth saying. `nil` means
    /// the detail page has no 来源 row.
    static func sourceNote(
        for provider: ProviderRateLimit.Provider,
        claudeUsesDesktopBundledCLI: Bool
    ) -> String? {
        switch provider {
        case .codex, .zCode:
            return nil
        case .claudeCode:
            // Only the one case where the data comes from something the user
            // did not install themselves.
            return claudeUsesDesktopBundledCLI ? "Claude Desktop" : nil
        case .kimiCode:
            return "官方 CLI 登录"
        case .grok:
            return "本机订阅记录"
        case .cursor:
            return "客户端登录"
        case .antigravity:
            return "官方 agy 登录"
        case .opencodeGo:
            return "本机 API Key，不读对话内容"
        }
    }
}

/// One product's page: the switch first, then its status and where the data
/// comes from, then whatever `QuotaSettingsCatalog.page(for:)` says it can
/// configure.
struct QuotaProductDetailView: View {
    @Environment(AppState.self) private var appState
    let product: QuotaProduct

    var body: some View {
        Form {
            Section {
                Toggle("启用", isOn: selectionBinding)
                    .tint(.green)
                    .disabled(toggleDisabled)

                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        Text(appState.quotaProductStatusText(product))
                        // Re-runs local detection for every product, as the
                        // former 「重新检测本机产品」 button did.
                        Button("重新检测") {
                            appState.rediscoverQuotaProducts()
                        }
                    }
                }

                if let note = QuotaSettingsCatalog.sourceNote(
                    for: product.provider,
                    claudeUsesDesktopBundledCLI: appState.claudeUsesDesktopBundledCLI
                ) {
                    LabeledContent("来源", value: note)
                }
            }

            switch QuotaSettingsCatalog.page(for: product.provider) {
            case .standard:
                EmptyView()
            case .zCodeAPIKey:
                ZCodeAPIKeySection()
            }
        }
        .formStyle(.grouped)
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { appState.isQuotaProviderSelected(product.provider) },
            set: { newValue in
                Task {
                    await appState.setQuotaProductSelected(product.provider, selected: newValue)
                }
            }
        )
    }

    /// Turning a product off is always allowed; turning one on is accepted for
    /// every catalog product, so a switch only locks for an unknown provider.
    private var toggleDisabled: Bool {
        !appState.isQuotaProviderSelected(product.provider)
            && !appState.canSelectQuotaProvider(product.provider)
    }
}

/// ZCode's region and user-entered key. Each region has its own Keychain item;
/// switching region clears the field and lets `AppState` re-read that item.
private struct ZCodeAPIKeySection: View {
    @Environment(AppState.self) private var appState

    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Picker("区域", selection: Binding(
                get: { appState.zCodeQuotaRegion },
                set: { region in
                    apiKey = ""
                    message = nil
                    errorMessage = nil
                    Task { await appState.setZCodeQuotaRegion(region) }
                }
            )) {
                ForEach(ZCodeQuotaRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)

            HStack(spacing: 8) {
                SecureField(
                    "API Key",
                    text: $apiKey,
                    prompt: Text(appState.zCodeAPIKeyConfigured ? "新 Key" : appState.zCodeQuotaRegion.apiKeyName)
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                Button(appState.zCodeAPIKeyConfigured ? "更新" : "保存") {
                    Task { await save() }
                }
                .disabled(
                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSaving
                )
                if appState.zCodeAPIKeyConfigured {
                    Button("移除", role: .destructive) {
                        Task { await remove() }
                    }
                    .disabled(isSaving)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
        }
    }

    private func save() async {
        isSaving = true
        message = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            try appState.storeZCodeAPIKey(apiKey)
            apiKey = ""
            message = "已保存"
            if appState.isQuotaProviderSelected(.zCode) {
                await appState.refreshRateLimit(for: .zCode)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        isSaving = true
        message = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            try appState.storeZCodeAPIKey(nil)
            apiKey = ""
            message = "已移除"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
