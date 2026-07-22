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

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isConfigured {
                unconfiguredView
            } else {
                dashboardView
            }
        }
        .frame(width: 520)
        .background(Color(white: 0.04))
    }

    // MARK: - Unconfigured State

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
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
                .background(Color(white: 0.16))

            VStack(alignment: .leading, spacing: 16) {
                if let pendingUserCode {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.5))
                        Text("请确认浏览器中显示的验证码与下方一致")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
                    .cornerRadius(4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("验证码")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(white: 0.5))
                            .textCase(.uppercase)
                        Text(pendingUserCode)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .tracking(3)
                    }
                }

                if let setupError {
                    Text(setupError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                Button {
                    let task = Task { await runDeviceFlow() }
                    deviceFlowTask = task
                } label: {
                    HStack(spacing: 6) {
                        if deviceFlowState == .awaitingApproval {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        }
                        Text(deviceFlowState == .awaitingApproval ? "等待浏览器确认…" : "登录并链接数据")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
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
                    .foregroundStyle(Color(white: 0.6))
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
                .background(Color(white: 0.16))

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.isInitialDataLoad || (!appState.hasLoadedUsageData && appState.buckets.isEmpty) {
                        rateLimitSection
                        FilterTagsView()
                        loadingDashboardView
                    } else if !appState.hasAnyData {
                        rateLimitSection
                        emptyStateView
                    } else {
                        dashboardContent
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 560)

            Divider()
                .background(Color(white: 0.16))

            // Footer
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private var dashboardContent: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                // Rate-limit row gets its own block separated from the usage
                // dashboard by a divider so quota and consumption stats stay distinct.
                rateLimitSection
                FilterTagsView()
                    .zIndex(10)
                SummaryCardsView()
                BarChartView()
                DistributionChartsView()
            }
            .opacity(appState.isRefreshingData ? 0.72 : 1)
            .animation(.easeInOut(duration: 0.2), value: appState.isRefreshingData)

            if appState.isRefreshingData {
                refreshOverlay
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isRefreshingData)
    }

    @ViewBuilder
    private var rateLimitSection: some View {
        if appState.codexRateLimitEnabled || appState.claudeRateLimitEnabled {
            // zIndex must beat FilterTagsView's (10): the quota hover tooltip
            // overflows below the card, and the filter row would otherwise
            // paint over it.
            RateLimitCardView()
                .zIndex(20)
            Divider()
                .background(Color(white: 0.16))
                .padding(.vertical, 2)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Vibe Usage")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                if AppConfig.isDev {
                    Text("DEBUG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }

                // Keep the persistent update affordance beside the app title,
                // where it remains visible without competing with footer actions.
                if updaterViewModel.availableUpdate != nil {
                    Button {
                        updaterViewModel.checkForUpdates()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 10))
                            Text("发现更新")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.15))
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("发现新版本，点击更新")
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
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.12))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.18), lineWidth: 0.5))
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
            .foregroundStyle(Color(white: 0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(white: 0.12))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.18), lineWidth: 0.5))
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
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
                case .syncing:
                    ProgressView()
                        .controlSize(.mini)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                if appState.syncStatus == .syncing {
                    Text("同步中...")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.38))
                } else if case .error(let msg) = appState.syncStatus {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.38))
                        .lineLimit(1)
                } else if let lastSync = appState.lastSyncTime {
                    Text("上次同步: \(Formatters.formatRelativeTime(lastSync))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.38))
                } else {
                    Text("就绪")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.38))
                }
            }

            Spacer()

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
                        .font(.system(size: 12))
                    Text("关闭")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color(white: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
    }

    // MARK: - States

    private var loadingDashboardView: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                SkeletonSummaryCards()
                SkeletonBlock(height: 238)
                SkeletonDistributionGrid()
            }
            .redacted(reason: .placeholder)
            .opacity(0.78)

            refreshOverlay
                .padding(.top, 90)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var refreshOverlay: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("加载中")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.66))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        .allowsHitTesting(false)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Color(white: 0.3))
            Text("暂无数据")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.5))
            Text("使用 AI 编程工具后数据将自动同步")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.38))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}

private struct SkeletonSummaryCards: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(height: 70)
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
    }
}

private struct SkeletonDistributionGrid: View {
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(height: 190)
            }
        }
    }
}

private struct SkeletonBlock: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 0.09))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
