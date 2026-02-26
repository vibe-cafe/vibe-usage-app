import SwiftUI

/// Main popover container — full dashboard view
struct PopoverView: View {
    @Environment(AppState.self) private var appState
    @State private var setupApiKey = ""
    @State private var isValidatingKey = false
    @State private var setupError: String?

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            if !appState.isConfigured {
                unconfiguredView
            } else {
                dashboardView
            }
        }
        .frame(width: 520)
        .background(Color(white: 0.04))
        .task {
            if appState.isConfigured && appState.buckets.isEmpty && !appState.isLoadingData {
                await appState.fetchUsageData()
            }
        }
    }

    // MARK: - Unconfigured State

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                if AppConfig.isDev {
                    Text("DEBUG")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .background(Color(white: 0.16))

            VStack(alignment: .leading, spacing: 16) {
                // API Key input
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Text("粘贴 API Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            if let url = URL(string: "\(AppConfig.defaultApiUrl)/usage/setup") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("获取 Key")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8))
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.4, green: 0.6, blue: 1.0))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("vbu_...", text: $setupApiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color(white: 0.08))
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
                }

                // Error
                if let setupError {
                    Text(setupError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                // CTA
                Button {
                    Task { await validateAndSaveKey() }
                } label: {
                    HStack(spacing: 6) {
                        if isValidatingKey {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        }
                        Text(isValidatingKey ? "验证中..." : "开始使用")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(setupApiKey.isEmpty || !setupApiKey.hasPrefix("vbu_") || isValidatingKey)
            }
            .padding(16)
        }
    }


    private func validateAndSaveKey() async {
        setupError = nil
        isValidatingKey = true
        defer { isValidatingKey = false }

        let client = APIClient(baseURL: AppConfig.defaultApiUrl, apiKey: setupApiKey)
        do {
            let response = try await client.validateKeyAndFetch()
            // Key valid — save config, load data, show dashboard
            appState.configure(apiKey: setupApiKey, apiUrl: AppConfig.defaultApiUrl)
            appState.buckets = response.buckets
            appState.hasAnyData = response.hasAnyData
        } catch let error as APIClient.APIError {
            if case .unauthorized = error {
                setupError = "API Key 无效，请检查后重试"
            } else {
                setupError = "网络错误: \(error.localizedDescription)"
            }
        } catch {
            setupError = "验证失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .background(Color(white: 0.16))

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if appState.isLoadingData && appState.buckets.isEmpty {
                        loadingView
                    } else if !appState.hasAnyData {
                        emptyStateView
                    } else {
                        FilterTagsView()
                        SummaryCardsView()
                        BarChartView()
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 300, maxHeight: 560)

            Divider()
                .background(Color(white: 0.16))

            // Footer
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        @Bindable var state = appState

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                if AppConfig.isDev {
                    Text("DEBUG")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            // 查看详情 — right after title
            Button {
                if let url = URL(string: "\(AppConfig.defaultApiUrl)/usage") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 3) {
                    Text("查看详情")
                        .font(.system(size: 10))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .medium))
                }
                .foregroundStyle(Color(white: 0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(white: 0.12))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)

            Spacer()

            // Time range selector
            HStack(spacing: 2) {
                ForEach(TimeRange.allCases, id: \.rawValue) { range in
                    Button {
                        state.timeRange = range
                        Task {
                            await appState.fetchUsageData()
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 11, weight: appState.timeRange == range ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(appState.timeRange == range ? Color(white: 0.16) : Color.clear)
                            .foregroundStyle(appState.timeRange == range ? .white : Color(white: 0.5))
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Settings — NSWindow directly (SwiftUI scenes don't work in LSUIElement MenuBarExtra)
            Button {
                SettingsWindowController.shared.show(appState: appState)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.5))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 0) {
            // Sync status
            HStack(spacing: 6) {
                switch appState.syncStatus {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
                case .syncing:
                    ProgressView()
                        .controlSize(.mini)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }

                if appState.syncStatus == .syncing {
                    Text("同步中...")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.38))
                } else if case .error(let msg) = appState.syncStatus {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.38))
                        .lineLimit(1)
                } else if let lastSync = appState.lastSyncTime {
                    Text("上次同步: \(Formatters.formatRelativeTime(lastSync))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.38))
                } else {
                    Text("就绪")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.38))
                }
            }

            Spacer()

            // Refresh button
            Button {
                Task {
                    await appState.triggerSync()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("更新数据")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color(white: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(appState.syncStatus == .syncing)

            // Quit button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text("关闭")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color(white: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("加载数据中...")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(Color(white: 0.3))
            Text("暂无数据")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.5))
            Text("使用 AI 编程工具后数据将自动同步")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.38))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}
