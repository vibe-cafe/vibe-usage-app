import SwiftUI

/// Main popover container — full dashboard view
struct PopoverView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @State private var deviceFlowState: DeviceFlowUIState = .idle
    @State private var pendingUserCode: String?
    @State private var setupError: String?
    @State private var deviceFlowTask: Task<Void, Never>?

    enum DeviceFlowUIState {
        case idle
        case awaitingApproval
    }

    private var palette: ThemePalette {
        appState.appTheme.palette
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isConfigured {
                unconfiguredView
            } else {
                dashboardView
            }
        }
        .frame(width: 520)
        .background(palette.background)
        .preferredColorScheme(appState.appTheme.colorScheme)
    }

    // MARK: - Unconfigured State

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                if AppConfig.isDev {
                    Text("DEBUG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                .background(palette.border)

            VStack(alignment: .leading, spacing: 16) {
                if let pendingUserCode {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.tertiaryText)
                        Text("请确认浏览器中显示的验证码与下方一致")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.card)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border, lineWidth: 1))
                    .cornerRadius(4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("验证码")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.tertiaryText)
                            .textCase(.uppercase)
                        Text(pendingUserCode)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                            .tracking(3)
                    }
                }

                if let setupError {
                    Text(setupError)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.danger)
                }

                Button {
                    let task = Task { await runDeviceFlow() }
                    deviceFlowTask = task
                } label: {
                    HStack(spacing: 6) {
                        if deviceFlowState == .awaitingApproval {
                            ProgressView()
                                .controlSize(.small)
                                .tint(palette.selectedText)
                        }
                        Text(deviceFlowState == .awaitingApproval ? "等待浏览器确认…" : "登录并链接数据")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.selectedBackground)
                .foregroundStyle(palette.selectedText)
                .disabled(deviceFlowState == .awaitingApproval)

                if deviceFlowState == .awaitingApproval {
                    Button {
                        cancelDeviceFlow()
                    } label: {
                        Text("取消，重新开始")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(16)
        }
    }


    private func runDeviceFlow() async {
        setupError = nil
        deviceFlowState = .awaitingApproval
        pendingUserCode = nil
        defer { deviceFlowState = .idle }

        let baseURL = AppConfig.defaultApiUrl
        let hostname = Host.current().localizedName?.replacingOccurrences(of: ".local", with: "")
        let device: DeviceCodeResponse
        do {
            device = try await requestDeviceCode(baseURL: baseURL, clientName: "Vibe Usage.app", hostname: hostname)
        } catch {
            setupError = "无法连接服务端：\(error.localizedDescription)"
            return
        }

        pendingUserCode = device.userCode
        if let url = URL(string: device.verificationUriComplete) {
            NSWorkspace.shared.open(url)
        }

        let intervalNs = UInt64(max(device.interval, 1)) * 1_000_000_000
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))

        while Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: intervalNs)
            if Task.isCancelled { return }
            let res: DevicePollResponse
            do {
                res = try await pollDeviceCode(baseURL: baseURL, deviceCode: device.deviceCode)
            } catch {
                continue
            }
            if let apiKey = res.apiKey {
                pendingUserCode = nil
                appState.configure(apiKey: apiKey, apiUrl: res.apiUrl ?? baseURL)
                await appState.fetchUsageData()
                return
            }
            switch res.error {
            case "authorization_pending", nil:
                continue
            case "access_denied":
                setupError = DeviceFlowError.denied.localizedDescription
                pendingUserCode = nil
                return
            case "expired_token":
                setupError = DeviceFlowError.expired.localizedDescription
                pendingUserCode = nil
                return
            default:
                setupError = "服务端返回未知错误：\(res.error ?? "unknown")"
                pendingUserCode = nil
                return
            }
        }
        setupError = DeviceFlowError.expired.localizedDescription
        pendingUserCode = nil
    }

    /// Abort an in-flight device flow so the user can re-link immediately
    /// instead of waiting out the 15-minute timeout. Cancelling the task makes
    /// runDeviceFlow() return at its next checkpoint; its `defer` resets the
    /// UI state back to idle.
    private func cancelDeviceFlow() {
        deviceFlowTask?.cancel()
        deviceFlowTask = nil
        pendingUserCode = nil
        setupError = nil
        deviceFlowState = .idle
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
                .background(palette.border)

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.isLoadingData && appState.buckets.isEmpty {
                        loadingView
                    } else if !appState.hasAnyData {
                        RateLimitCardView()
                        emptyStateView
                    } else {
                        // Rate-limit row gets its own block separated from the
                        // usage dashboard by a divider so the visual boundary
                        // between "subscription quota" and "consumption stats"
                        // is unambiguous.
                        // zIndex bumps it above the sibling sections that follow
                        // so the per-row hover tooltips, which overflow the
                        // card edge downward, stay above the divider / filters.
                        RateLimitCardView()
                            .zIndex(1)
                        Divider()
                            .background(palette.border)
                            .padding(.vertical, 2)
                        FilterTagsView()
                        SummaryCardsView()
                        BarChartView()
                        DistributionChartsView()
                    }
                }
                .padding(16)
            }
            .frame(height: 560)

            Divider()
                .background(palette.border)

            // Footer
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                if AppConfig.isDev {
                    Text("DEBUG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            Spacer()

            headerLinkButton(title: "详情", url: "\(AppConfig.defaultApiUrl)/usage")
            headerLinkButton(title: "排行榜", url: "\(AppConfig.defaultApiUrl)/usage/rank")

            // Settings — NSWindow directly (SwiftUI scenes don't work in LSUIElement MenuBarExtra)
            Button {
                SettingsWindowController.shared.show(appState: appState, updaterViewModel: updaterViewModel)
            } label: {
                Text("设置")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.control)
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func headerLinkButton(title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(palette.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.control)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 0) {
            // Sync status
            HStack(spacing: 6) {
                switch appState.syncStatus {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.success)
                case .syncing:
                    ProgressView()
                        .controlSize(.mini)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.success)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.danger)
                }

                if appState.syncStatus == .syncing {
                    Text("同步中...")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedText)
                } else if case .error(let msg) = appState.syncStatus {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedText)
                        .lineLimit(1)
                } else if let lastSync = appState.lastSyncTime {
                    Text("上次同步: \(Formatters.formatRelativeTime(lastSync))")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedText)
                } else {
                    Text("就绪")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedText)
                }
            }

            Spacer()

            // App update — only shown when Sparkle has found a newer version.
            // Clicking re-runs checkForUpdates() which surfaces Sparkle's standard
            // install dialog (one-click confirm → install → relaunch).
            if updaterViewModel.availableUpdate != nil {
                Button {
                    updaterViewModel.checkForUpdates()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                        Text("发现更新")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(palette.link)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }

            // Refresh button
            Button {
                // CLI sync upload + rate-limit fetch are independent (different
                // data sources, different IO) — fire both at once instead of
                // making the rate-limit request wait on the CLI subprocess.
                Task {
                    async let sync: Void = appState.triggerSync()
                    async let limits: Void = appState.refreshAllRateLimits()
                    _ = await (sync, limits)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                    Text("更新数据")
                        .font(.system(size: 11))
                }
                .foregroundStyle(palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .disabled(appState.syncStatus == .syncing)

            // Quit button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                    Text("关闭")
                        .font(.system(size: 11))
                }
                .foregroundStyle(palette.tertiaryText)
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
                .font(.system(size: 13))
                .foregroundStyle(palette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(palette.mutedText)
            Text("暂无数据")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.tertiaryText)
            Text("使用 AI 编程工具后数据将自动同步")
                .font(.system(size: 13))
                .foregroundStyle(palette.mutedText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}
