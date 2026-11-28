import SwiftUI

/// Main popover container — full dashboard view
struct PopoverView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isConfigured {
                unconfiguredView
                    // The login code temporarily increases the panel's height.
                    // Keep this content at its ideal height so the quota cards
                    // cannot absorb that space after the flow is cancelled.
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                dashboardView
            }
        }
        .frame(width: 520)
        .background(Color(white: 0.04))
        // The quota tooltip is drawn here — the panel's topmost layer — because
        // the card that opens it sits inside the horizontal card scroller and
        // this popover's vertical `ScrollView`, both of which clip their
        // content. As a root overlay the tooltip is above every scroller, card
        // and following section, so nothing can crop or paint over it.
        .overlayPreferenceValue(QuotaTooltipPreferenceKey.self) { payload in
            GeometryReader { geo in
                if let payload {
                    QuotaTooltipOverlay(
                        payload: payload,
                        rowRect: geo[payload.anchor],
                        containerSize: geo.size
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: payload?.key)
        }
    }

    // MARK: - Unconfigured State

    private var unconfiguredView: some View {
        // The sign-in is shared with the new panel (`AppState.deviceLink`).
        let link = appState.deviceLink
        return VStack(alignment: .leading, spacing: 0) {
            // Quota monitoring is local and does not require a Vibe account.
            // Keep the normal header (including Settings) available so an
            // unlinked user can also configure ZCode or export diagnostics.
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .background(Color(white: 0.16))

            VStack(alignment: .leading, spacing: 14) {
                classicStyleReminder
                rateLimitSection

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("用量同步（可选）")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(white: 0.72))
                        Text("登录 Vibe Usage 后可同步 Token 与查看统计；不影响上方订阅配额。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.42))
                    }

                    if let pendingUserCode = link.userCode {
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

                    if let setupError = link.failureReason {
                        Text(setupError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    Button {
                        link.start()
                    } label: {
                        HStack(spacing: 6) {
                            if link.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.black)
                            }
                            Text(link.isRunning ? "等待浏览器确认…" : "登录并链接数据")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .disabled(link.isRunning)

                    if link.isRunning {
                        Button {
                            link.cancel()
                        } label: {
                            Text("取消，重新开始")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(white: 0.6))
                    }
                }
            }
            .padding(16)
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
                VStack(alignment: .leading, spacing: 14) {
                    // An upgraded user's one-time banner: content, so the
                    // panel keeps its 620 pt and the rest moves down.
                    classicStyleReminder
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

    /// The upgraded user's banner (#113, `InterfaceStylePreference.showsClassicReminder`).
    @ViewBuilder
    private var classicStyleReminder: some View {
        if appState.interfaceStyle.showsClassicReminder {
            ClassicStyleReminderBanner {
                appState.acceptClassicStyleReminder()
            } notNow: {
                appState.interfaceStyle.dismissClassicReminder()
            }
        }
    }

    @ViewBuilder
    private var rateLimitSection: some View {
        // Always keep the section visible: an intentionally empty selection
        // must still expose the selector so the user can add a product again.
        // No zIndex is needed for the quota tooltip — it renders in the
        // popover-root overlay, above every section here.
        RateLimitCardView()
        Divider()
            .background(Color(white: 0.16))
            .padding(.vertical, 2)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(AppConfig.displayName)
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

            headerLinkButton(title: "详情", url: appState.usageServer.url(for: "usage"))
            headerLinkButton(title: "排行榜", url: appState.usageServer.url(for: "rank"))

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

    private func headerLinkButton(title: String, url: URL?) -> some View {
        Button {
            if let url {
                NSWorkspace.shared.open(url)
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
                .contentShape(Rectangle())
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
                .contentShape(Rectangle())
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
