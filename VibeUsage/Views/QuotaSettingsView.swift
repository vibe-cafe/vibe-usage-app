import SwiftUI

/// Settings facts per quota product. The list and every detail page are built
/// from `AppState.quotaProducts`, i.e. the `QuotaProductRegistry` catalog; the
/// switches below are exhaustive, so a new catalog provider does not compile
/// until it states which page it gets. Adding a provider is therefore one
/// catalog entry, plus a page case only when it has something to configure.
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

    /// Catalog order with ZCode last, the order this list has always had.
    static func listOrder(_ products: [QuotaProduct]) -> [QuotaProduct] {
        products.filter { $0.provider != .zCode } + products.filter { $0.provider == .zCode }
    }

    /// The list row's status line. `quotaProductStatusText` stays the single
    /// source of truth (the detail page prints it in full); only ZCode's long
    /// form is shortened to the one fact a row can act on. Wording this map
    /// does not recognize passes through untouched instead of being invented.
    static func compactStatus(_ status: String) -> String {
        if status.contains("已配置") { return "已配置" }
        if status.contains("需配置") || status.contains("未检测到") { return "待配置" }
        return status
    }

    static func rowStatus(for product: QuotaProduct, statusText: String) -> String {
        page(for: product.provider) == .zCodeAPIKey ? compactStatus(statusText) : statusText
    }
}

/// 订阅配额: the product list (switch per product, as before) on the left, the
/// selected product's page on the right.
struct QuotaSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation

    private var products: [QuotaProduct] {
        QuotaSettingsCatalog.listOrder(appState.quotaProducts)
    }

    private var selectedProduct: QuotaProduct? {
        if let requested = navigation.quotaProvider,
           let product = products.first(where: { $0.provider == requested }) {
            return product
        }
        return products.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: Binding(
                    get: { selectedProduct?.provider },
                    set: { provider in
                        // Clicking empty space clears a List selection; keep
                        // the page on the current product instead.
                        if let provider { navigation.quotaProvider = provider }
                    }
                )) {
                    ForEach(products) { product in
                        QuotaProductRow(product: product)
                            .tag(product.provider)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))

                Button("重新检测本机产品") {
                    appState.rediscoverQuotaProducts()
                }
                .controlSize(.small)
            }
            .frame(width: 210)
            .padding(.leading, 20)
            .padding(.vertical, 20)

            if let selectedProduct {
                QuotaProductDetailView(product: selectedProduct)
            }
        }
    }
}

private struct QuotaProductRow: View {
    @Environment(AppState.self) private var appState
    let product: QuotaProduct

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: product.provider)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(product.displayName)
                    .lineLimit(1)
                Text(QuotaSettingsCatalog.rowStatus(
                    for: product,
                    statusText: appState.quotaProductStatusText(product)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: selectionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
                .disabled(toggleDisabled)
        }
        .padding(.vertical, 2)
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

/// One product's page: its status, where the data comes from, and whatever
/// `QuotaSettingsCatalog.page(for:)` says it can configure.
private struct QuotaProductDetailView: View {
    @Environment(AppState.self) private var appState
    let product: QuotaProduct

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: appState.quotaProductStatusText(product))
                if let note = QuotaSettingsCatalog.sourceNote(
                    for: product.provider,
                    claudeUsesDesktopBundledCLI: appState.claudeUsesDesktopBundledCLI
                ) {
                    LabeledContent("来源") {
                        Text(note)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    ProviderIcon(provider: product.provider)
                        .frame(width: 14, height: 14)
                    Text(product.displayName)
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
