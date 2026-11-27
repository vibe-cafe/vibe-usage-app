# AGENTS.md

AI agent guidance for the vibe-usage-app repository.

## Repository Map

```
vibe-usage-app/                    # SwiftUI macOS menu bar app (SPM, Swift 6, macOS 14+)
├── .github/workflows/ci.yml       # CI: version check, offline CLI gate test, launcher copy check, bundled-Node launcher run, debug/release build, swift test (no signing)
├── Package.swift                  # SPM manifest (Sparkle dependency)
├── VibeUsage/
│   ├── Info.plist                 # Bundle metadata (versions, Sparkle SUFeedURL, SUPublicEDKey)
│   ├── App/
│   │   ├── VibeUsageApp.swift     # @main entry, AppDelegate lifecycle hooks
│   │   └── AppResources.swift     # Bundle.appResources helper
│   ├── Models/
│   │   ├── AppState.swift         # @Observable central state (buckets, filters, timeRange, sync)
│   │   ├── InterfaceStyle.swift   # Observable panel and Settings style, rollout and first-launch choice
│   │   ├── AppConfig.swift        # Version string, API URL, debug/release config
│   │   ├── UsageBucket.swift      # Codable data model (source, model, project, hostname, tokens, cost) + server-supplied `names`
│   │   ├── Config.swift           # Shared ~/.vibe-usage config; app-owned fields + unknown CLI-field-preserving writes
│   │   └── SyncHistory.swift      # Last 10 sync summaries (typed fields only) in the app's preferences
│   ├── Views/
│   │   ├── PopoverView.swift      # Main dashboard container (520px wide popover)
│   │   ├── SummaryCardsView.swift # 4 stat cards (cost, total tokens, cached tokens, active time)
│   │   ├── BarChartView.swift     # Custom-drawn bar chart (hourly/daily trend)
│   │   ├── DistributionChartsView.swift  # 4 donut pie charts (terminal, tool, model, project)
│   │   ├── FilterTagsView.swift   # Filter pills for source/model/project/hostname
│   │   ├── SettingsView.swift     # Settings window root: 168pt sidebar (通用 / 订阅配额 / 数据同步 / 数据目录（高级）/ 关于) + the chosen page
│   │   ├── Settings/              # One file per page, plus SettingsTheme (dark palette + switch/button/segment/field), SettingsModel (pages, navigation, display rules, per-window state), ProviderGlyph + SVGPathParser (monochrome provider marks)
│   ├── Services/
│   │   ├── APIClient.swift        # HTTP client for /api/usage (Bearer auth with vbu_ key) + unauthenticated device-flow helpers (requestDeviceCode/pollDeviceCode)
│   │   ├── SyncEngine.swift       # Orchestrates CLI sync (runs the CLI through cli-bootstrap.mjs)
│   │   ├── SyncScheduler.swift    # 30-minute interval auto-sync timer
│   │   ├── CLIBridge.swift        # Executes vibe-usage CLI config commands
│   │   ├── CLIProcessRunner.swift # Background process wait, temporary output files, explicit deadlines
│   │   ├── RuntimeDetector.swift  # Chooses the runtime: bundled Node (probed once per launch) → system Node ≥ 20 → Bun
│   │   ├── CLILauncher.swift      # Reads cli-bootstrap.mjs output (failure / cached-CLI notice) and its cache
│   │   ├── UpdaterViewModel.swift # Sparkle SPUUpdater bridge + SPUUpdaterDelegate proxy (publishes availableUpdate)
│   │   ├── RateLimitCoordinator.swift # Orchestrates quota refreshes (cache-then-live for both providers)
│   │   ├── CodexUsageAPI.swift    # Live Codex usage endpoint client (auth.json token, zero-quota GET)
│   │   ├── CodexRateLimitReader.swift # Offline Codex fallback: session-JSONL scan
│   │   ├── ClaudeUsageProbe.swift # Live Claude quota: spawns a Claude Code binary, stdio `get_usage`
│   │   ├── ClaudeUsageCache.swift # Claude instant-paint: ~/.claude.json, then Desktop's usage history
│   │   ├── OpenCodeGoUsageAPI.swift # Live OpenCode Go quota: reads the CLI's own auth.json key, GET /zen/go/v1/usage
│   │   ├── CursorLogin.swift      # Cursor separate sign-in: our own Keychain item, `login cursor --json` / `--refresh` through the CLI, handed over on stdin
│   │   ├── DiagnosticSummary.swift # Whitelisted plain-text summary for 「复制诊断信息」
│   │   ├── DiagnosticCollector.swift # Gathers its typed fields (names, booleans, versions, templates)
│   │   ├── LegacyStatuslineRetirement.swift # One-time undo of the pre-0.5.7 statusline hook
│   │   ├── DirectoryWatcher.swift # kqueue directory watcher
│   │   ├── MenuBarController.swift # NSStatusItem + custom borderless popover panel (multi-line title, animated open/close)
│   │   ├── PopoverPanel.swift     # NSPanel subclass that becomes key for TextField input
│   │   ├── SettingsWindowController.swift  # NSWindow wrapper for settings (700 × 460, dark, full-size content, entry destinations)
│   │   └── ActivationCoordinator.swift     # Centralizes NSApp.activationPolicy across popup + Settings + updates
│   ├── Utils/
│   │   ├── Formatters.swift       # Number, cost, date, time formatting
│   │   ├── DiagnosticRedactor.swift # Last-line filter over the copied diagnostic summary
│   │   ├── DateOrder.swift        # Module-local Date <= / >= (never delete; see Known Constraints)
│   │   └── Log.swift              # Debug logging
│   └── Resources/
│       ├── Assets.xcassets/       # App icon, menu bar icon
│       └── cli-bootstrap.mjs      # CLI launcher — byte-for-byte copy of vibe-usage-windows src-tauri/resources/
├── scripts/
│   ├── build-app.sh               # Build + sign + notarize pipeline; supports --universal / --arch; bundles + checks Node
│   ├── bundled-node.env           # Pinned Node.js version + both darwin tar.xz SHA256s
│   ├── fetch-node.sh              # Download, double-verify, (lipo) the pinned Node into one executable
│   ├── node.entitlements          # The bundled Node's two JIT entitlements
│   ├── check-cli-bootstrap.sh     # Launcher copy must equal vibe-usage-windows (--github <ref> / --sibling)
│   ├── check-version.sh           # Guards AppConfig/Info.plist version sync + monotonic CFBundleVersion
│   └── generate-appcast.sh        # Generate Sparkle appcast.xml
└── dist/                          # Build output (gitignored)
    ├── Vibe Usage.app             # Contents/Helpers/node = bundled Node
    ├── VibeUsage.dmg
    ├── VibeUsage.zip
    └── appcast.xml
```

## Quick Commands

```bash
swift build                              # Debug build
swift build -c release                   # Release build
swift test                               # Unit tests (opt-in acceptance tests skip by default)
node --test scripts/check-cli.test.mjs   # Offline CLI contract-gate tests
./scripts/check-cli-bootstrap.sh --sibling   # Launcher copy vs ../vibe-usage-windows origin/main
./scripts/fetch-node.sh --universal --output /tmp/node   # Pinned Node, verified, universal
./scripts/check-version.sh               # Validate version sync across AppConfig + Info.plist
./scripts/build-app.sh                   # Build + codesign .app for host arch (runs check-version.sh first)
./scripts/build-app.sh --universal       # Build universal (arm64 + x86_64) .app
./scripts/build-app.sh --universal --notarize  # Release pipeline: universal + sign + notarize + DMG
./scripts/generate-appcast.sh            # Generate appcast.xml from dist/VibeUsage.zip
```

CI (`.github/workflows/ci.yml`) runs `check-version.sh`, `check-cli.test.mjs`, `check-cli-bootstrap.sh --github <ref>` (normally `main` of vibe-usage-windows; a PR that waits on a Windows launcher change may point it at that branch and must set it back before merging), fetches the pinned universal Node, ad-hoc signs it with hardened runtime + `scripts/node.entitlements` and runs the launcher's `--version` with it, then debug/release `swift build` and `swift test` on `macos-26` with Xcode 26.6 for every PR and push to `main`; opt-in acceptance tests remain skipped, with no Developer ID signing or release. Its shallow checkout has no tags, so `check-version.sh` only checks AppConfig/Info.plist version consistency and an integer build number; comparison against the previous `v*` tag is left to the release machine.

## Network Privacy Principle (highest rule, decided 2026-11-24)

This is the product's highest rule. It outranks features and convenience; where
any other rule, issue, or contributor request conflicts with it, this rule wins.
Many users reach overseas services only through a proxy, and what they care
about most is a vendor seeing their real IP together with their vendor account.

1. **Follow the user's network.** Every network request made by Vibe Usage or
   by any process it launches (the CLI, Claude Code, `agy`, `grok`, …) honors
   the proxy configuration on the user's machine: system proxy, PAC, proxy
   environment variables, TUN. A request that cannot honor it is not sent.
2. **Stricter for requests made with a vendor account.** A request made with
   the user's AI-vendor account (quota reads, usage fetches) is sent only when
   we can confirm it will leave through the user's network settings. This
   includes requests that a process we launch (Claude Code, `agy`, `grok`, …)
   makes with its own login. When the route cannot be confirmed, the request
   is not sent, and the panel says why.
3. **Wrong egress: pause, don't push through, and don't bother the user.**
   When no proxy is detected, the user is not asked; instead we detect which
   country this request would leave from: one request carrying no account or
   sign-in data, on the same route, of which only the country code is read.
   When the egress is in a region the vendor does not serve (mainland China,
   for example), the requests in point 2 pause (requests without a vendor
   account, such as npm or update checks, are not covered by this point), the
   panel says why (for example "network egress is in mainland China, reading
   paused"), and reading resumes on its own once the proxy is back; an egress
   in a supported region reads as usual. Requests to domestic (mainland
   Chinese) vendors are not checked and read as usual. The check is described
   in the privacy notes and can be switched off in settings; for the rare case
   where detection is wrong, settings keep a manual option (decided 2026-11-24,
   replacing the earlier "ask the user once").
4. **Never change the user's settings.** Telemetry or non-essential traffic the
   user turned off stays off, including inside processes we launch.
5. **Only necessary requests; documented and switchable.** Every kind of
   network activity is described in the privacy notes, and every product can be
   switched off on its own.
6. **Every change answers to it, without a worse experience.** Any change that
   adds or alters network behavior states, point by point, how it meets 1–5,
   and whether the user experience gets worse. Compliance must not come at the
   cost of a worse experience: exhaust the alternatives first, and only when
   every path has been tried and none keeps both, bring the tried paths and the
   trade-offs to the maintainer for a decision. "Stop reading it" or "stop
   offering it" is not a proposal on its own. This is a required part of the
   approval request (see Architecture Approval Gate), and cross-review checks
   against it.

Scope of the promise: on our side we never route around the user's network
settings, and when unsure we do not send. Sites that the user's own proxy rules
send direct are respected. Our own server, the npm registry, GitHub update
checks, and the egress check of point 3 (seen by the vendor's CDN) see the
user's egress IP; they carry no vendor account and must be described in the
privacy notes.

Existing code does not fully comply yet. The fixes are tracked separately and
land under this principle; until then, do not widen any gap.

## Architecture Approval Gate

Issues and PRs are proposals, not approval to change architecture or ship a
release. Explicit maintainer approval is required before changing privacy or
security semantics, defaults/onboarding, identity/dedup behavior, source of
truth, cross-repository API/config contracts, or automatic update behavior.
This remains true during a broad issue sweep. A change that adds or alters network
behavior (including fixes to proxy handling) always needs this approval, and the
request must answer each point of the Network Privacy Principle above.

The Mac app is a consumer of the backend + CLI contract. It must not introduce
an app-local setting that overrides backend-owned Usage policy, reinterpret
shared `~/.vibe-usage/config.json` fields as a new control plane, or pin the CLI
to an exact version.

**CLI version policy (decided 2026-09-17):** the app always invokes
`@vibe-cafe/vibe-usage@latest` (`RuntimeDetector.defaultPackageSpecifier`) and
never freezes an exact version — a pin silently rots (e.g. a pinned build that
predates the feature the app calls) and it costs users every CLI fix until the
next app release. Compatibility is a *protocol* problem, not a version-number
problem: every structured CLI reply the app depends on carries a protocol
version (e.g. `QuotaCLIBridge.schemaVersion`), an unknown version or a missing
command must surface an actionable "update the CLI" message instead of an empty
card, and the app must keep working against CLI releases newer than itself.
`VIBE_USAGE_CLI_PACKAGE` stays the only way to point the app at an unreleased
build (integration tests).

**Cached fallback (approved 2026-11-14, 《Mac 自带 Node 方案》).** Since the
bundled-Node release the app runs the CLI through `cli-bootstrap.mjs`, the same
launcher as the Windows app. Every run still asks the registry for `latest`
first and runs it; only when `latest` cannot be resolved, downloaded, verified
or installed does the newest *complete* version in `~/.vibe-usage/cli-cache/`
run instead, with one `vibe-usage launcher notice:` line on stderr. That is a
fallback, not a pin, and is consistent with this policy (the Windows app has
done the same since 2026-11-11). The launcher asks the registry named in the
user's `~/.npmrc` (`@vibe-cafe:registry`, else `registry`; https only, never one
the file holds credentials for), like `npx` did, and the official registry
otherwise. Before approval, present the current and proposed
invariants, all affected repositories, existing-user migration, release
ordering, and rollback. Signed/notarized release creation happens only
after that design approval; passing tests and possessing release credentials
are not approval.

Reference incident: CLI v0.10.15 implemented issue #49 as local-first privacy
policy and was fully reverted in v0.10.16. Treat any equivalent app/CLI/backend
proposal as a cross-repository RFC.

## Architecture

### App Type
LSUIElement menu-bar app with an optional Dock/Cmd-Tab presence. `AppDelegate` owns a `MenuBarController` that manages an `NSStatusItem` plus a borderless `PopoverPanel` (custom NSPanel) hosting the SwiftUI dashboard. We dropped `MenuBarExtra` so the status item can render multi-line text via `NSHostingView` (cost over tokens) and the panel can use a custom open/close animation anchored to the icon. When the user enables "show in Dock", `ActivationCoordinator` promotes the app to `.regular`, assigns the bundled Dock icon, and AppKit activation events (Dock click or Cmd-Tab switch to Vibe Usage) call `MenuBarController.presentPanelForAppActivation()` so the dashboard opens or foregrounds like the menu-bar item. Focus moving to **another application** (an `NSWorkspace.didActivateApplicationNotification` for a different bundle id) closes the dashboard again via `dismissPanelForAppDeactivation()`, unless Settings or a Sparkle modal is visible. `AppDelegate` deliberately does **not** dismiss on `applicationWillResignActive`: the app also resigns active for its own reasons — closing the Settings window flips the activation policy back to `.accessory` when the Dock icon is hidden, which deactivates the app — and that used to close the popover together with Settings.

### State Management
`AppState` is `@Observable` and injected via `@Environment`. All views read from it. No Combine, no ObservableObject (except `UpdaterViewModel` which bridges Sparkle's KVO).

`AppState` creates its interface-style preference before `initialize()` writes the menu-bar and quota defaults. Once `AppConfig.interfaceStyleReleased` opens, a saved style wins. On the first eligible launch, a known key in the Mac app's persistent preferences identifies an upgrade (classic), including an unlinked install or empty quota selection. A fresh or CLI-only install starts modern. The choice is saved immediately to the same preferences domain. External-test builds default to modern in their own domain. With the gate closed, ordinary builds use classic and skip style preference reads and writes.

### View Hierarchy
```
VibeUsageApp → AppDelegate → MenuBarController (NSStatusItem + PopoverPanel)
└── PopoverView (520px wide, hosted in NSHostingView pinned to panel.contentView)
    ├── unconfiguredView          # First-run device-flow linking (browser login → poll → save key)
    └── dashboardView
        ├── headerBar             # Title, web links (详情/排行榜), settings
        ├── ScrollView
        │   ├── RateLimitCardView # Codex / Claude subscription quota cards
        │   ├── FilterTagsView    # Source/model/project/hostname filter pills
        │   ├── SummaryCardsView  # 4 stat cards
        │   ├── BarChartView      # Trend chart (hourly or daily)
        │   └── DistributionChartsView  # 4 donut charts (2x2 grid)
        └── footerBar             # Sync status, refresh, quit
```

### Data Flow
1. Before every dashboard fetch, including the refresh after CLI sync, reload the shared config and keep the in-memory snapshot if the file cannot be read. `UsageServer` maps legacy production addresses in memory to `https://vibefriends.com` and preserves custom servers. `APIClient.fetchUsage(range:)` calls that server's `/api/usage` with Bearer token auth.
2. Response decoded into `[UsageBucket]`, stored in `AppState.buckets`
3. Views compute filtered data locally: `appState.buckets.filter { ... appState.filters ... }`
4. Charts aggregate filtered buckets by time key or dimension

Active time uses the approved 2026-11-25 model-time contract. Alongside each usage read, the same authenticated `APIClient` and system-routed URL session read `/api/usage/activity` with the dashboard range, timezone, granularity and repeated source/project/hostname filters. `AppState.activity` supplies the server's deduplicated total and actual hourly/daily periods to both cards and charts. AI work time adds up concurrent sessions. Dividing it by active time gives average concurrency. The classic card keeps its original look: only the value changes. AI work time (when positive), average concurrency (when available) and, for partial totals, the first recorded local date appear only in its tooltip; the maintainer ruled out a second line on the card (2026-11-27). Before the first recorded period, or after a failed read, active time is unknown. A recorded idle period is zero. Usage buckets load independently.

### Time Range (today / 24H / 7D / 30D / 90D / custom)
`TimeRange` (`AppState.swift`) has two hourly-granularity cases that look similar but mean different things — the split mirrors `vibe-cafe@f5f022b`, where the single rolling "1D" pill confused users who read it as "today" but watched the number shrink as the earliest hour rolled off.

- `.today` (UI: 「今天」) — local-midnight → now, fixed start. Only grows through the day.
- `.oneDay` (UI: 「24H」, raw value still `"1D"` for state stability) — rolling last 24 hours.
- `.sevenDays`, `.thirtyDays`, `.ninetyDays` — fixed day-count ranges.
- `.custom` — user-selected local date bounds, sent as `from` / `to` query params.

Today requests `from=localMidnight` while rolling 24h requests `days=1`. The today-cutoff is also applied client-side via `TimeRange.startCutoff` so all filtered views and the menu-bar display share the same local-midnight semantics. `BarChartView`'s hourly fill loop keys off `appState.timeRange == .today` to start at midnight (slot count grows from 1 → 24) instead of "23 hours ago" for the rolling-24h case. Every `/api/usage` request includes `tz=TimeZone.current.identifier`.
Multi-day API buckets carry UTC instants for the viewer's local midnight. Daily bucket/session keys must convert those instants through the current timezone; taking the raw ISO prefix shifts UTC+ users back one day and leaves today's 7D bar empty.

### Loading & Filtering
`AppState` distinguishes first load from refresh:
- `isInitialDataLoad` / `!hasLoadedUsageData` → show layout-matched skeleton blocks under a loading pill.
- `isRefreshingData` → keep the current dashboard visible, dim it, and overlay a small loading pill.

Time-range changes and custom-date Apply refresh both reads. Tool, project and hostname changes refetch only activity, whose union depends on the selected rows. Model changes and all filtering of cost and tokens remain local.

### Chart Hover & Scroll
`BarChartView` is split into a parent that computes the O(n) `chartData`
aggregation and a `ChartContent` child that owns the hover state, so a hover
change never re-runs the aggregation. The bar strip uses a **single**
`.onContinuousHover` region mapping cursor X → bar index (not one `.onHover`
per bar — that was 24–90 `NSTrackingArea`s). A `ScrollWatcher` (`@Observable`,
local `.scrollWheel` `NSEvent` monitor, 150 ms-debounced, never consumes the
event) flips `isScrolling` for the duration of a scroll gesture; while it is
set the hover layer drops hit-testing and the `.active` handler bails, so the
chart subtree stays static mid-gesture. Without this the popover `ScrollView`
stutters / sticks whenever the pointer is parked over the 趋势 chart, because
SwiftUI keeps delivering hover updates as the content slides under the cursor.

### Quota Tooltip Layer
The 订阅配额 card tooltip (Token / 时间 / 重置 breakdown) is **not** drawn by the
card. The card publishes the hovered row — formatted values plus an
`anchorPreference` on the row — as `QuotaTooltipPreferenceKey`, and
`PopoverView`'s root overlay renders it through `QuotaTooltipOverlay`
(`VibeUsage/Views/RateLimitCardView.swift`). The card is inside the horizontal
card scroller *and* the dashboard's vertical `ScrollView`, both of which clip
their content, so a card-local tooltip was cut off at the card's bottom edge;
the panel root is the one layer above every scroller, card, and following
section. `QuotaTooltipPlacement` then positions the tooltip against the
resolved row rect and the measured tooltip size: below the row normally, above
it when the panel's bottom is too close, clamped to `edgeInset` when either
axis would leave the panel (row scrolled past a panel edge). Keep new hover
surfaces that overflow their container on this pattern rather than fighting the
clip with padding or `zIndex`.

### Sync Pipeline
Release builds always run `@latest` (CLI version policy above): the app must work against any published CLI, and compatibility is proven by the versioned contracts it consumes — `scripts/check-cli.mjs` runs that proof against the package the app will actually fetch. The explicit external-test build is the only path that bundles a specific CLI checkout; that bundle is validated with `--from-local` and never ships as the general release. `VIBE_USAGE_CLI_PACKAGE` remains the pre-publish local integration-test override.

`scripts/check-cli.mjs` validates the actual npm package (current `latest`) before normal `build-app.sh` packaging. It requires schema v1 discovery/fetch for Kimi, ZCode, Grok, Cursor, and Antigravity, using isolated credential-free directories. `--from-local` validates a packed checkout for pre-publish integration or the explicit external-test build; it must never bypass the published-package check for an ordinary app. See `docs/RELEASING.md` for CLI-before-app ordering.

1. `SyncScheduler` fires every 30 minutes (background upload + fetch)
2. `SyncEngine` runs `<runtime> cli-bootstrap.mjs sync`; `CLIBridge` does the same for config and quota commands
3. `RuntimeDetector` chooses the runtime (see **Bundled Node** below)
4. After a successful sync, `fetchUsageData()` reads the CLI's latest config and refreshes the dashboard. Device linking uses the configured server for both code and poll, then saves the mapped address returned on approval (or the requesting server if omitted). The CLI owns on-disk domain migration.
5. Opening the popover calls `fetchUsageDataIfNeeded()` (60s debounce) — fetch only, no upload
6. Settings can persist one legacy `codexExtraHome` plus per-source isolated runtime roots (Codex / Grok / Antigravity, e.g. Multica homes) through the CLI (`config roots` / `add-root` / `remove-root`, CLI ≥ 0.10.20) — both editors sit on the Settings 数据目录（高级）page; sync then scans them together with each tool's default directory (`$CODEX_HOME` / `~/.codex` for Codex). The app never writes these fields itself — `CLIBridge` shells out so the CLI stays the single writer. Config writes must preserve unknown CLI fields, especially local privacy controls and `deviceId`. `VIBE_USAGE_CONFIG_DIR` / `VIBE_USAGE_CLI_PACKAGE` are integration-test hooks (the latter forces `npx` with a local package path).

### Bundled Node (approved 2026-11-14, 《Mac 自带 Node 方案》)
The app ships the official Node.js 24 (`scripts/bundled-node.env`; both architectures merged into one universal executable) at `Contents/Helpers/node`, so new users need no Node of their own. `RuntimeDetector.detect()` picks, in order: (1) the bundled Node, if `BundledNodeProbe` succeeds — once per app launch, on first use (never at launch on the main thread), it runs a tiny loop that makes V8 compile optimized code and prints `process.version`, 5s cap; a missing file, a launch failure, a signal (what the system does to a JIT without its entitlement), a timeout or a bad answer each map to a fixed `BundledNodeStatus`; (2) a system `node` from the search path, 22.5+ preferred (built-in `node:sqlite`), else 20+, each read with `--version`; (3) Bun. All three run the same `cli-bootstrap.mjs` from the SwiftPM resource bundle. `defaults write ai.vibecafe.vibe-usage cliRuntimePreference system` (support switch, no UI) skips (1) entirely; with no system runtime the footer then says so. `VIBE_USAGE_CLI_PACKAGE` and the external-test build still run their package through the system `npx` and are unaffected.

- **The bundled Node is never put on `PATH`.** A system runtime's directory still goes first on `PATH`, as before; with the bundled one, tools the CLI starts (`agy` while reading quotas, …) keep finding the user's own Node. `Runtime.environment(base:)` is the single place that builds the CLI's environment, including `VIBE_USAGE_SURFACE=mac-app` / `VIBE_USAGE_SURFACE_VERSION`, which reach the CLI unchanged because the launcher imports it in-process; both callers (`SyncEngine`, `CLIBridge.runCLI`) then add the system proxy with `SystemProxy.cliEnvironment(base:)` (see **System proxy**).
- **The launcher is owned by the Windows repository** (`vibe-usage-windows` `src-tauri/resources/cli-bootstrap.mjs`, tests in its `tests/cliBootstrap.test.ts`). Change it there first, then copy it byte for byte to `VibeUsage/Resources/`; `scripts/check-cli-bootstrap.sh` compares the two in CI (`--github <ref>`) and `build-app.sh` stops a release whose copy differs from the sibling checkout's `origin/main` (`--sibling`).
- **Its two stderr beginnings** (`CLILauncher`, same rules as the Windows app's `sync_history.rs`): `vibe-usage launcher: …` means the CLI never ran → `launchFailed` / `launcherFailed` with a `launcherStage` (`network` / `registry` / `download` / `install` / `other`, from the message's fixed beginning); `vibe-usage launcher notice: stage=…` means a cached CLI ran → the notice is removed before the result is classified and before any error line is shown, and only its stage word is kept as `cliFallback`. A crash inside the CLI's `run()` carries no prefix and is judged as the CLI's own failure. The footer shows our own copy for the four named launcher stages. The `npm err!` / `error: … registry` rules stay for the `npx` test hooks.
- **Cache**: `~/.vibe-usage/cli-cache/<version>/` (the launcher's default when `VIBE_USAGE_CONFIG_DIR` is unset; ~0.85 MB per version). The launcher never deletes old versions yet (known, shared with Windows).
- **When nothing can run the CLI** (probe failed and no system Node ≥ 20 or Bun), the existing footer/card style shows 「自带 Node 无法启动，也未找到 Node.js 或 Bun」 (or 「已设为用系统运行环境，但未找到 Node.js 或 Bun」 with the switch); quota cards say 「缺少 Node.js」. `AppState.runtimeAvailable` follows the latest sync.

CLI subprocesses use `CLIProcessRunner`: blocking waits run on a dispatch worker, stdout/stderr go to private temporary files (removed after completion), and deadlines are reported as timeout rather than launcher stderr. Never wait for a subprocess to exit before draining `Pipe` output: a full pipe deadlocks the child, and an inherited pipe can outlive it. A one-second SIGTERM grace period is followed by SIGKILL for an unresponsive process. Exit zero remains success even when Bun prints dependency-resolution progress to stderr.

### System proxy (network-privacy principle, 2026-11-24)
The workspace `AGENTS.md` rule 1: follow the user's proxy settings, in the processes we start too. `URLSession.shared` always followed the system proxy, but the CLI (Node) and Claude Code read only proxy environment variables, so with a proxy client's common "system proxy" mode they connected directly. `SystemProxy` now resolves the macOS settings per URL and hands them on:

- **Resolution.** `CFNetworkCopySystemProxySettings` is read again for every call (nothing cached); `CFNetworkCopyProxiesForURL` applies the bypass list; a PAC answer is evaluated by the system (`CFNetworkExecuteProxyAutoConfigurationURL` / `…Script`, 3 s per URL and 6 s per batch of URLs, on a GCD worker's run loop in a private mode — never the main thread, never JavaScript of our own). The **first** entry is the route: `PROXY a; DIRECT` pins `a` and never falls back to direct; a first `DIRECT` is the user's own rule. A PAC that cannot be evaluated is `.unresolved` and **fails closed**: requests and children are pointed at a closed local port (`failClosedURL`, `127.0.0.1:1`), never sent direct. Measured on macOS: the system drops a PAC `SOCKS5` directive (so `SOCKS5 a; SOCKS a; DIRECT` resolves to SOCKS `a`, and a lone `SOCKS5 a` to nothing → unresolved) and an `HTTPS a` directive (`HTTPS a; DIRECT` → direct, the same thing `URLSession` itself does).
- **CLI.** `SystemProxy.cliEnvironment(base:)` resolves the hosts the CLI reaches (`cliHosts`) plus, by their real URL, the registry the launcher asks (`launcherRegistry`, read like `cli-bootstrap.mjs`: quotes stripped, https only, a registry with credentials in `~/.npmrc` skipped) and the configured server, and sets `HTTPS_PROXY` / `HTTP_PROXY` to the HTTP proxy most of them use, `NO_PROXY` to the bypass list Node would use (lowercase `no_proxy` first) plus loopback (`[::1]` too) and the hosts the PAC sends direct (written to `no_proxy` too when the user had one; a `*` stays exactly `*`), and `NODE_USE_ENV_PROXY=1`. A SOCKS-only proxy goes as `socks5://` (plus `ALL_PROXY`) **without** the switch: Node 24 with the switch refuses to start on `socks5h://` and Node's https cannot follow SOCKS; the CLI (≥ the release with `src/proxy-tunnel.js`, vibe-cafe/vibe-usage#196) follows it through its own SOCKS5 tunnel. Proxy variables already in the app's environment (`ALL_PROXY` included) win over the system's, as on Windows: nothing is resolved; the proxy each scheme really uses (the CLI's order — the scheme's own variable, then `ALL_PROXY`, for https an `HTTP_PROXY` last) is written out as explicit `HTTPS_PROXY` / `HTTP_PROXY` with a scheme, plus the switch, unless either choice is SOCKS.
- **Claude Code.** `ClaudeUsageProbe.fetch` passes `SystemProxy.claudeLaunch(base:)` (Anthropic's hosts). Claude Code speaks only HTTP proxies, so an HTTP proxy is handed over as for the CLI, and a **SOCKS-only** system proxy goes through `ClaudeSOCKSRelay`, which used to be a direct connection with the user's Claude login. The relay listens on 127.0.0.1 only, on a port the system picks, for one probe: started right before it, stopped (listener and every connection) when `fetch` returns. It accepts only `CONNECT` to `anthropic.com` / `claude.com` / `claude.ai` and their subdomains on port 443, only with the random credential made for that relay (handed to Claude Code inside `HTTPS_PROXY`, so `Proxy-Authorization`; anything else `407` / `403` / `405`), and copies bytes without looking inside TLS. Each connection follows the route resolved for its host when the probe started (kept for the whole probe, so a proxy client restarting mid-probe cannot turn it into a direct connection; an Anthropic host not resolved then takes the SOCKS proxy): SOCKS5 with the host *name* (never a local DNS answer), an HTTP proxy by a chained `CONNECT`, the user's own direct rule directly, and an unresolvable route refused (`502`), never direct. A relay that cannot start points Claude Code at the closed port. Measured 2026-11-24 with the real Claude Code 2.1.330 and a stand-in SOCKS5 on 127.0.0.1: the quota read succeeded and the stand-in saw `api.anthropic.com:443` by name only.
- **Codex and OpenCode Go** call `SystemProxy.data(for:)`: one session per request whose `connectionProxyDictionary` pins the route (direct, HTTP, SOCKS, or the closed port when unresolved), so a proxy that is down fails the request instead of letting it go direct. Our own server (`APIClient`) stays on `URLSession.shared`.
- **Login-item launch** (`LoginLaunch`). macOS marks a login-item launch on the open-application Apple Event (`keyAELaunchedAsLogInItem`); since that mark is undocumented for `SMAppService.mainApp`, an enabled login item launching within 300 s of system start counts too. Such a launch looks like any other (the dashboard opens on activation as before), but when a proxy is configured its network reads wait for it, since the proxy client may not be up yet right after login (network-privacy principle, rules 1, 2 and 6): `AppState.waitForLaunchNetwork()` returns once `LoginLaunch.waitForProxy` sees the system route (PAC included) of the sync server or any host the app or the CLI reads (`proxyProbeURLs`; a PAC often sends only the vendors through the proxy) point at a proxy that accepts a TCP connection, polled every 2 s, or after about 120 s (checked between rounds), and **at once when every route is direct** (no proxy configured; a PAC that cannot be evaluated yet still counts as configured). A proxy variable in the app's own environment does not count, since Codex and OpenCode Go follow the system settings only. The wait is started only when there is network work (linked, or a quota product selected). Every sync (manual ones too) and every live quota read (Codex, Claude, OpenCode Go, the CLI quotas) await it; a sync whose account changed meanwhile (reset, relink) is dropped, and a reset cancels the launch sync that has not started; cached paints do not, so cards show their last numbers meanwhile. Until 2026-11-24 a launch with no system proxy waited the full two minutes, because some proxy clients set the system proxy only once started; the maintainer replaced that with the egress check (next item): such a launch syncs at once, and Codex, Claude and Antigravity pause on a wrong egress until a later read sees the proxy or a supported egress. Any other launch, and a relink, does not wait.
- **Egress check** (`EgressCheck`, network-privacy principle rule 3; the maintainer decided the direction, the vendors and the setting on 2026-11-24 (made one three-way menu on 2026-11-25), plan 「代理与地区风险-修复方案」§3.4). Codex (`CodexUsageAPI.send`, before every attempt, since each attempt reads the route again) and Claude (`ClaudeUsageProbe.fetch`, after the policy check, only when a binary exists) call it before anything carries the account. Codex is checked when the system route of its usage URL is `.direct` and that URL is on `chatgpt.com` / `chat.openai.com` (a `chatgpt_base_url` relay is the user's choice; OpenAI sees the relay). Claude is judged by the environment Claude Code is really started with (`claudeTraceHost`): `ClaudeUsageProbe.fetch` builds `SystemProxy.claudeLaunch` first (the app's own proxy variables, or the system proxy with the hosts a PAC sends direct added to `NO_PROXY`, or the SOCKS relay, or the fail-closed port), then the check overlays the proxy keys of Claude Code's own `settings.json` `env` (`claudeSettingsProxyEnvironment`, only those keys read; a proxy set only there is common). Claude Code follows `HTTPS_PROXY` / `HTTP_PROXY` (either case), no SOCKS or `ALL_PROXY`; with such a proxy a host goes direct only when the bypass list (`NO_PROXY` and `no_proxy` together) names it, and without one every host does (`claudeRoute`). How Claude Code reads an entry such as `.api.anthropic.com` or `*.anthropic.com` is not settled (three cross-review rounds read its code three ways), so both ways count: `.direct(host)` only for a host bypassed under every reading (`bypassSurely`: `*` or the host itself), and the check goes there; `.unsure` when a host is bypassed only under some reading (`bypassPossibly`: also a domain of it, with or without `.` / `*.`), which pauses as `egressUnconfirmed` (or `proxyNotDetected` with the manual setting; sent as before with the check off) — the anonymous check never goes direct to a host the user's settings may proxy, and a host that may go direct is never let through unchecked. Proxy keys from an organization's managed settings are not read (niche; recorded in the plan). A proxy route — HTTP, SOCKS, the relay, the fail-closed `.unresolved` — is never checked. The check: one `GET https://<host>/cdn-cgi/trace` on a session with every proxy off (`SystemProxy.configuration(for: .direct)`), no cookie store, credential store or cache, no redirect followed, 5 s, at most 4 KiB, and only `loc=` is kept. `CN` / `HK` / `MO` throw `EgressCheck.Paused(.regionUnsupported)`, no answer / `XX` / Tor's `T1` `.unconfirmed`; the setting 「没检测到代理时」 (`EgressCheck.Mode`, stored as `egressMode`) decides the rest: 「自动判断（推荐）」 (`.auto`, the default) checks; 「暂停读取」 (`.pause`) throws `.proxyNotDetected` without a check; 「照常读取」 (`.allow`) sends as before. Development builds stored two switches instead (`egressCheckEnabled`, `egressRequireLocalProxy`, never released); `EgressCheck.mode` maps them onto the menu (require-proxy on → 暂停读取, check off → 照常读取) and `setMode` removes them. `Paused` classifies as `.absent`, so the coordinator keeps a reading already on screen with the reason under it (「来源：缓存 · 网络出口在中国大陆，已暂停读取」) or shows the reason as the empty card's line, with no retry (`LiveFailure.egressRegionUnsupported` / `.egressUnconfirmed` / `.proxyNotDetected`, `isPause`; Settings 「已暂停」, also while older numbers stay on the card, which lights the tab's amber dot too: `quotaWarningSnapshot` counts an `.ok` snapshot with `isNetworkPause`; the tab's tooltip then says 「读取已暂停」 instead of 「数据异常」). While a card is paused by one of the three egress reasons (`LiveFailure.isEgressPause`, whatever its status; not `proxyUnsupported`), `refreshCodexIfNeeded` / `refreshClaudeIfNeeded` / `refreshCLIProvidersIfNeeded` skip their 60-second debounce, so a proxy turned on is picked up at the next open (the check still keeps its own one-minute answer). Answers live in `EgressCheck.Checker` (memory): per host and network (`networkFingerprint()`, a hash of the up, non-loopback, non-link-local addresses, so a network switch or a TUN adapter coming or going re-checks), 10 minutes for a supported country, 1 minute otherwise, one check per host at a time. The CLI checks Antigravity itself; `Runtime.environment(base:)` always passes the menu as both variables, `VIBE_USAGE_EGRESS_CHECK=1|0` (0 only for 照常读取) / `VIBE_USAGE_REQUIRE_PROXY=1|0` (1 only for 暂停读取) (a value the user exported for the terminal must not override Settings), and `cliHosts` includes `chatgpt.com` and `api.anthropic.com`, the CLI's stand-ins for Google, so a PAC's answer for them reaches the CLI. The route is read once by the check and again by the request; a proxy that disappears in those milliseconds is recorded, not guarded. Debug builds may set `VIBE_USAGE_EGRESS_TEST_REGION` (`none` = no answer) to show a paused card without a request. Coverage: `Tests/VibeUsageTests/EgressCheckTests.swift`.

Coverage: `Tests/VibeUsageTests/SystemProxyTests.swift` (resolution from injected settings dictionaries — HTTPS proxy and bypass list, SOCKS, PAC by the system including the first-answer rule and an unevaluable PAC; the variables handed to the CLI and Claude Code, the user's own variables, Node's bypass precedence, fail-closed children; the launcher's registry rules; pinned sessions against a stand-in proxy on 127.0.0.1 that records an HTTP `CONNECT` and a SOCKS5 greeting; login-launch detection and the wait for the proxy), `Tests/VibeUsageTests/ClaudeSOCKSRelayTests.swift` (the relay against a stand-in SOCKS5 that forwards to a local echo server: host name handed over, credential, allowed hosts and port, unresolved route, stop; what Claude Code's environment gets). The tests never read or change the machine's settings.

### Rate-Limit Refresh
No background timer. `RateLimitCoordinator` is driven entirely by user-visible events:
- **Approved 2026-09-19 — quota meter layout:** generic time windows render first from shortest to longest, so every provider that has both windows shows `5h` above `7d`. Exact generic aliases normalize to compact labels (`Daily` → `1d`, `Weekly` / `1w` → `7d`); provider-specific/model/feature meters retain their relative order afterward. The CLI canonicalizes schema-v1 live/cache results and both desktop apps repeat the rule defensively for older snapshots. Providers without a 5h window start with their first real window; the UI never invents an empty slot.
- The dashboard and Settings share one ordered, persisted product selection (`selectedQuotaProductIds`), with **no display cap**: every enabled product keeps its own card and the row scrolls sideways once it is wider than the popover. First launch selects locally detected ready products except Antigravity, which is only ever turned on by the user (maintainer 2026-11-26: Google does not support third-party quota reads on personal plans, and Settings carries no note about it; existing selections are kept as they are); a one-time migration preserves the legacy Codex/Claude toggles exactly, while the former stored `cursor-grok` id maps to Cursor (never to the newly fetchable Grok adapter). `quotaSelectionInitialized` distinguishes a fresh install from a user intentionally selecting nothing. Local discovery never reads credentials or reaches the network, and a product discovered after initialization never replaces the user's choices. `codexRateLimitEnabled` / `claudeRateLimitEnabled` are compatibility projections over this selection while their native adapters remain in place.
- `QuotaProductRegistry` lists Kimi Code, ZCode, Grok, and Cursor independently and recognizes ordinary local app/config/CLI presence without opening credentials. Kimi, ZCode, and Grok use the CLI's schema-versioned quota contract. Grok (active read, maintainer-approved 2026-11-25, 《Grok主动读取-审批门方案》) is read by the CLI: once the official `grok` binary is found (`$GROK_HOME/bin`, `PATH`, `~/.local/bin`) and the CLI's egress check lets the read go ahead, it starts `grok agent --no-leader stdio` in a temporary directory with `GROK_DISABLE_AUTOUPDATER=1`, sends only `initialize` and `_x.ai/billing`, and stops the process within 10 s; Grok asks xAI (`cli-chat-proxy.grok.com`) with its own sign-in, which neither the CLI nor the app reads, and no session, prompt or quota use happens. Grok follows only proxy environment variables, which is what `SystemProxy.cliEnvironment` hands the CLI (system proxy and PAC included). A live answer is `source: live`; not signed in is `unauthorized` (no older numbers); any other failure, no binary, or a paused egress falls back to the final 2 MiB of the official `~/.grok/logs/unified.jsonl`, accepting only the structured `billing: fetched credits config` event and projecting only utilization, current-period bounds, subscription tier, and event timestamp (`source: local`). A period without `creditUsagePercent` (Grok omits zero) reads as 0%, as in Grok's own UI. A paused read answered from the log is `ok` + `source: local` with `pauseReason`, so the card keeps the log's numbers and names the pause (#190 rules below); with no log record it is `unsupported` + `pauseReason`, shown like Antigravity's. A log fallback after a failed read carries the CLI's `failureReason` (`programNotFound`, `timedOut`, `programOutdated`, `programNoAnswer`, `unrecognizedResponse`); not signed in is `unauthorized` + `credentialsMissing`. Nothing of Grok's is cached by the CLI (Grok writes its own log record per answer). Cursor and Antigravity are ready CLI-backed products. Cursor reads only its own app access-token row to call the official usage-summary endpoint, or the separate sign-in Vibe Usage keeps (**Cursor separate sign-in** below). Antigravity (reworked 2026-11-24, maintainer-approved, 《Antigravity额度读取-封号风险与新做法》) asks Google only after Antigravity was used on this Mac (the CLI compares names, sizes and modification times in the desktop / agy / IDE conversation stores), at most once per 5 minutes, backing off 5 → 60 minutes after failures; otherwise the CLI answers from its own record (`~/.vibe-usage/antigravity-quota.json`): a window whose reset passed is 0% if Antigravity sat unused since, and left out if it was used. `RateLimitCoordinator` therefore takes every `.ok` Antigravity answer from the CLI as is instead of keeping the newer `dataAsOf`: the record can drop a row under the same timestamp. A read tries the official `agy -p /usage --output-format json` first, then a running desktop's own loopback language server, and only then a short-lived desktop engine started under the installed bundle's real version; `agy` children get `AGY_CLI_DISABLE_AUTO_UPDATE=true` and do-nothing browser launchers first on `PATH`, so a failed silent sign-in cannot open a browser tab. Neither adapter reads browser cookies, another app's keychain directly, network traffic, or UI. The CLI owns credential isolation; the app must not resurrect an old Cursor/Antigravity success after a failure or missing result. Existing saved selections stay unchanged.
- Kimi reads the official Kimi Code 2.x OAuth file (`$KIMI_CODE_HOME/credentials/kimi-code.json`, otherwise `~/.kimi-code/credentials/kimi-code.json`) through the shared CLI, with the legacy `$KIMI_SHARE_DIR` / `~/.kimi` file as fallback, and calls the official `/coding/v1/usages` endpoint. The adapter accepts the current 2.x `usages` response and the legacy quota response. The shared CLI is the sole Vibe-side owner of Kimi refresh behavior: when the access token is near expiry or a usage request returns 401, it uses Kimi's standard OAuth refresh grant, serializes Vibe refreshes across processes, re-checks concurrent Kimi CLI rotation, and atomically writes the rotated credential at mode `0600`. No token reaches app output, diagnostics, quota cache, or upload state. ZCode accepts only a user-entered regional API key. BigModel (domestic) and Z.ai (overseas) use separate Vibe Usage Keychain items; the app removes both inherited variables, injects only `BIGMODEL_API_KEY` or `Z_AI_API_KEY` for the explicitly selected region, and never reads ZCode's OAuth database. Existing Z.ai keys remain assigned to Z.ai; a fresh configuration displays BigModel by default but performs no request until the user saves a key and selects ZCode. Normalized CLI quota cache entries are scoped by a one-way hash of region plus credential and contain no secrets. The Mac validates `schemaVersion == 1` before displaying results, so a CLI contract mismatch fails closed per card.
- **Cursor separate sign-in (maintainer-approved 2026-11-25, workspace notes 《Cursor-加密凭据-方案》; CLI side vibe-cafe/vibe-usage#210).** Cursor 3.27+ encrypts the login it keeps in `state.vscdb` (issue #144) and nothing here decrypts it. Instead the user signs in to Cursor once more, for Vibe Usage, in Settings → 订阅配额 → Cursor (a disclosure block like ZCode's, `CursorLoginBlock`; copy word for word the Windows app's, workspace notes 《cursor-单独登录-App文案-两端对齐》): 未登录 → 「未登录」 (secondary text, maintainer 2026-11-26) + 「登录」; waiting → 「请在浏览器里确认；如果 Cursor 让你去邮箱确认，点完邮件里的链接再回来」 + 「取消」 (measured 2026-11-25: some accounts get a confirmation e-mail, link valid 10 minutes); signed in → the account's email + 「退出」; ended or lapsed → 「登录已失效」 + 「退出」 (no confirmation: Cursor already ended it) / 「重新登录」 (the maintainer's copy listed 重新登录 only; 退出 was added in cross-review so an ended sign-in, which keeps the CLI from falling back to another login, can be removed without signing in again). No explanatory line under it (maintainer, 2026-11-26); 「以 Cursor 命令行的身份登录，只用来读用量」 is in the README. `CursorLogin` (`@MainActor`, `CursorLogin.shared`, owned by `AppState.cursorLogin`) runs everything through the shared CLI with the system proxy (`SystemProxy.cliEnvironment`; `cliHosts` has `cursor.com` and `api2.cursor.sh`), so the app itself sends no Cursor request:
  - **Sign-in**: `login cursor --json`. Its stdout is streamed from a pipe (`CLIProcessRunner.run(onStdoutLine:)`), never a file. The first line `{"event":"open","url":…}` is opened in the default browser only when it is exactly `https://cursor.com/loginDeepControl` (`CursorLogin.signInPage`; anything else stops the CLI). `{"event":"credential"}` is stored verbatim in our own Keychain item (`KeychainCursorLoginStore`: account `cursor-login`, the ZCode keys' service `VibeUsageKeychain.service`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); `{"event":"error","code":…}` maps to our own copy (timeout / network / proxy / other). While it waits (up to 5 minutes) `SystemProxyWatch` watches `State:/Network/Global/Proxies`; when the system proxy settings change the CLI, started with the old ones, is stopped (「代理设置变了，请重新登录」) rather than left polling and reading the profile on a stale route; quitting the app (`applicationWillTerminate`) stops it too. A Keychain read that failed at launch (locked, a prompt cancelled) is tried again at the next CLI run. The app reads only `email` and `expiresAt` from the record. A new sign-in or a sign-out cancels a Cursor quota read in flight (`RateLimitCoordinator.cursorCredentialContextDidChange`), reads the card again, and a sign-in syncs at once so the paused history fills in (the CLI backfills by week).
  - **Every sync and Cursor quota read** passes `--cursor-login-stdin` with the record on stdin (`CLIProcessRunner.run(standardInput:)`, a pipe marked `F_SETNOSIGPIPE`) — never the environment or argv, which processes the CLI starts would inherit. Within 7 days of `expiresAt` the app first runs `login cursor --refresh --json --cursor-login-stdin` (one renewal at a time; concurrent runs wait for it; a renewal that finishes after a sign-in or sign-out is dropped). `expired` replaces the record by `{version, rejectedAt, email}` (tokens gone); an incomplete renewal keeps the current record and waits 6 hours (in memory). When a run reports the passed sign-in rejected (quota `signIn: expired`, or the sync notice `Cursor 登录已失效（在 Vibe Usage 里登录的那一份）`, matched only) the app renews once; a quota read then reads Cursor again with the renewed record. When the record a renewal produced (due or after a rejection) is rejected before Cursor was seen accepting it (a live quota answer with numbers or without a window: `CursorLogin.noteAccepted`), it ends without another renewal, as the CLI ends a stored one; a re-read that fails after a renewal shows as a read failure, not 「已失效」 — otherwise every refresh would renew again and add a session on cursor.com. Sync reads the proxy after the renewal and takes the sign-in once more right before the CLI starts.
  - **Quota answers**: the CLI adds `signIn` (`required`: Cursor's own login cannot be read and there is no Vibe Usage sign-in; `expired`) to Cursor's `unsupported` result. `QuotaCLIBridge` maps them to `LiveFailure.signInRequired` / `.signInExpired`: card 「需要登录 Cursor」 / 「Cursor 登录已失效」 with a chevron, and the whole card opens Settings on the Cursor row (expanded while it needs a sign-in, `SettingsNavigation.opensConfiguration`); Settings 状态 「需登录」 / 「已失效」 (「已失效」 also while the card is off). After Cursor ended the app's sign-in the token-free record is still passed: the CLI takes it as a sign-in that exists but cannot be used (`signIn: expired`, Cursor skipped in sync, no request) instead of falling back to another login on this Mac (Cursor's own, the CLI's file), which may be another account; signing in again or 「退出」 ends that.
  - **CLI support**: the row offers sign-in only once `vibe-usage --version` (through the launcher) is 0.15.10 or newer, or a quota answer carried `signIn`; a no is asked again after a minute when the page appears again. A stored sign-in is always shown (its state and 「退出」; 「登录」 / 「重新登录」 wait for the check) and passed.
  - **Not done**: no decryption; nothing of Cursor's own is read (`state.vscdb` beyond the CLI's existing token row, `Local State`, Cursor's Keychain items); the login and renewal output never enters logs, diagnostics, the sync history or an error message; there is no sign-out request (Cursor has none): 「退出」 deletes the item; its confirmation is one sentence, 「只删除 Vibe Usage 里的这份登录，Cursor 编辑器不受影响。」 (maintainer, 2026-11-26: the longer text was too much), and how to revoke on cursor.com is in the README's privacy notes (Sessions lists it as 「Desktop App」, one more per renewal, up to 10 minutes to take effect; the Cursor editor is also 「Desktop App」). Cursor is not on the egress-check list (maintainer, 2026-11-24). A background service installed with `npx` cannot read the Keychain item; it uses `~/.vibe-usage/cursor-login.json` (`vibe-usage login cursor` in a terminal). Release order: the CLI with `login cursor` (0.15.10) on npm first, then this app. Coverage: `Tests/VibeUsageTests/CursorLoginTests.swift` (fake store and CLI), `CLIProcessRunnerTests` (stdin, streamed lines), `QuotaCLIBridgeTests` (`signIn`).
- **OpenCode Go is app-native, not CLI-backed** (2026-09-26, the mode the maintainer chose; login discovery widened 2026-11-24, maintainer-approved). `OpenCodeGoUsageAPI` reads OpenCode's own saved login from OpenCode's data home (`$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`, as OpenCode resolves it), in the CLI adapter's order, first usable wins: the 2.x `credential` table in `opencode.db` (read-only; current row per integration, active first then newest) — the `opencode-go` key, then the `opencode` integration (a service-account key, or an OpenCode account sign-in: its `access` token plus `metadata.orgID`, sent as `x-opencode-org-id`, only while `expires` is 0 or more than 60 s away) — then 1.x `auth.json` (`opencode-go`, then `opencode`, `type: "api"` only), read only when the table has no row for either integration and its `migration` table does not record `20260805200742_import_legacy_credentials` (2.x imports `auth.json` once and leaves the stale copy behind). The SQL extracts only the fields the request needs with `json_extract` from the current row per integration, never the refresh token; both `opencode` credential types are accepted only for the default Console, and an `opencode` key needs no workspace (a 1.x key imported by 2.x has none). Since OpenCode 2.4.0 new users can only connect through `opencode`, and 1.x's official Go docs store the key under `opencode-go`; reading only the `opencode-go` row and `auth.json` `opencode` (before 2026-11-24) showed both as not logged in. It calls the account-wide `GET https://opencode.ai/zen/go/v1/usage`, mapping its `rolling` / `weekly` / `monthly` percentages onto `ProviderRateLimit.meters` (labels 5h / Weekly / Monthly). `windowDuration` is stated only for the fixed 5h and 7-day windows; the monthly reset is a calendar month, so that row carries no duration and therefore no "% elapsed" bar rather than a guessed one. The credential is read per request, sent only as request headers, and never logged, cached, uploaded, or written; the app never rewrites or renews OpenCode's credential (renewal rotates OpenCode's refresh token, and racing OpenCode's own renewal can sign the user out of OpenCode) and never reads OpenCode's conversation store or any other provider's credential. An expired account sign-in sends nothing: `FetchError.signInExpired → .absent`, `LiveFailure.credentialsExpired`, card 「打开 OpenCode 后自动显示」, Settings 「需打开」. No login at all: `.credentialsNotFound`, card 「在 OpenCode 里登录后自动显示」, Settings 「需登录」 (Codex shows 「未找到登录信息」 / 「需登录」). There is deliberately **no on-disk snapshot cache** (unlike Codex): the call is one fast request, so a cold card shows its spinner instead of risking another login's numbers. A 403 `EntitlementError` is the endpoint's answer, not a failed read: it maps `FetchError.notSubscribed → .notApplicable`, which the coordinator turns into `.noData` with `EmptyReason.notEntitled` (「未订阅 OpenCode Go」) and no retry affordance — even over a reading already on screen, since after switching OpenCode to a workspace without Go the old numbers would be another workspace's — while 401 asks the user to re-login in OpenCode itself. It never appears in `usesQuotaCLI`, so the CLI envelope can neither carry nor be asked for it; selection, detection (`~/.local/share/opencode`), and the popover-open refresh (`refreshOpenCodeGoIfNeeded`) use the same product registry and path as every other card.
- **Diagnostics: what release builds may keep and export (rule changed 2026-11-09).** The maintainer Hogan approved revision 2 of the diagnostics plan under the Architecture Approval Gate on 2026-11-09 (「可以开工，你派活吧。 1、2、3我都同意。」), replacing the former rule that release builds contain no diagnostic writes or export entry. Three facilities, each with its own limits; adding a field to either release facility needs another gate approval:
  - **Release 「复制诊断信息」 (Settings → 关于 → 复制诊断信息).** Only when the user presses the button does the app build a plain-text summary (`DiagnosticCollector` → `DiagnosticSummary`), copy it to the clipboard, and show what was copied in a preview under the row. Nothing is uploaded or written to disk. Whitelist only: app/OS version, build kind and current interface style (modern / classic); the runtime the app uses — 「App 自带 Node / 系统 Node / Bun」 (`npx` for the test hooks) and its version, plus whether the `cliRuntimePreference` switch is set; the bundled Node's probe result (能启动 + version, or one fixed reason: 文件缺失 / 无法启动 / 被系统结束 / 超时 / 运行出错); whether the CLI starts and its version (one `--version` run through the launcher, 20s cap — sync output does not carry it), whether the launcher script is present, and the newest complete version in the launcher's cache (§2.6 fields, approved 2026-11-14 with the bundled-Node plan); the app's sync history (below); each quota card's state, 1a fixed reason and source; the Claude probe's per-candidate record from the latest completed probe (fixed path template such as `~/.local/bin/claude` or `PATH 第 N 项中的 claude`, initialize / get_usage timings, fixed reason, exit status — no version, because Claude Code updates itself and today's version must not be pinned on an older failure); the currently installed candidates in their own section with `claude --version` (5s cap each) and the count of `claude` on `$PATH`; whether a system proxy or `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` exists and whether it is a loopback address (never host, port, or credentials); names, never values, of `ANTHROPIC*` / `CLAUDE*` variables in the app's environment and of the `env` keys in Claude's `settings.json` (`$CLAUDE_CONFIG_DIR` or `~/.claude`), and whether `CLAUDE_CONFIG_DIR` is set; scheduler state; 「已配置 Key」 and the newest sync record's Key verdict — 未被服务器拒绝 only after a success, 被服务器拒绝 only after an explicit rejection, otherwise 无法判断 (same wording as the CLI and Windows); a 4-hex device tag hashed from the hostname. Never Claude Code's or the CLI's raw output, server bodies, real paths, hostnames, account handles, keys, or environment values; there is no Vibe account tag. `DiagnosticRedactor` then rescans the finished text (home → `~`; URLs, `/Users/…`, encoded `-Users-…` project directories, `vbu_`, `sk-`, `Bearer`, JWTs, emails and 40+ character tokens → `***`; a long all-upper-case `A-Z0-9_` variable name such as `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is kept). The `doctor --json` merge is a later step.
  - **Release sync history (default on).** `SyncHistoryStore` keeps the last 10 `SyncRecord`s, rolling, in the app's own preferences: start time, trigger (定时 / 启动时 / 手动), result (成功 / 失败 / 超时被 App 结束 / CLI 启动阶段失败), duration, one fixed reason, an HTTP status number for server errors, and (approved 2026-11-14 with the bundled-Node plan) the launcher's stage word for a launcher failure (`launcherStage`) and for a run that used the cached CLI (`cliFallback`, shown as 「用了本机缓存的 CLI（…）」, the Windows app's field). Older records lack the two fields and decode unchanged. `SyncEngine.outcome(for:)` only matches the CLI's text to choose the code; no text is stored. The app alone records the 120s timeout. Settings 「重置配置」 clears it.
  - **Test-build JSONL log (unchanged).** The exportable `TestDiagnosticLog` file stays a test-build facility only: it and its Settings export UI must remain guarded by `#if DEBUG` or the explicit external-test build flag, so ordinary Release binaries contain neither its log writes nor its export entry. The JSONL schema is typed and may contain only error codes, detected/selected provider ids, status/meter counts, timestamps, app/OS versions, build kind/number, and reviewed App/CLI version or commit identifiers; never add raw stderr, response bodies, request headers, credentials, account identifiers, environment overrides, or filesystem paths. Files stay inside the current user's `~/Library/Logs/Vibe Usage/`, use owner-only permissions, and are shared only when that user explicitly exports them. A locally re-signed Debug UI build may set `VIBE_USAGE_TEST_KEYCHAIN_SERVICE` to an empty test namespace so it never queries the release app's ZCode items or triggers an approval prompt, `VIBE_USAGE_QUOTA_UI_TEST=1` to show the quota dashboard without loading the production Vibe account config or starting its sync/upload scheduler, `VIBE_USAGE_SETTINGS_UI_TEST=1` to open the Settings window right after launch, and (together with the quota UI hook) `VIBE_USAGE_SAMPLE_USAGE=1` to fill the dashboard and menu bar with fixed sample usage (`AppState.sampleUsageBuckets`) for preview builds. All four hooks must remain inside `#if DEBUG`; Release always uses `ai.vibecafe.vibe-usage` and its normal account lifecycle.
- Popover open → selected providers only: native Codex/Claude plus the Kimi/ZCode/Grok/Cursor/Antigravity CLI adapters (60s debounce per provider; Antigravity 5 minutes, `RateLimitCoordinator.antigravityRefreshInterval`, since the CLI asks Google at most that often anyway). Neither path can prompt the user for another product's credentials.
- Footer "更新数据" → `refreshAll()` (parallel; the coordinator still skips disabled providers). A card-level retry refreshes only that provider.
- **Codex is network-first with a local fallback.** `CodexUsageAPI` GETs the zero-quota usage endpoint (`{base}/wham/usage`, base honors `chatgpt_base_url` in `~/.codex/config.toml` and `$CODEX_HOME`) with the OAuth access token + account id from `~/.codex/auth.json` — a plain-file read, no keychain, no prompts. This keeps the card fresh while Codex is idle and adds facts the JSONL can't provide: live `plan_type`, "window not enforced" semantics (see below), and `rate_limit_reset_credits`. The refresh chain: paint the *last live snapshot* instantly if the card is empty (persisted to `~/.vibe-usage/codex-rate-limits.json` as a minimal DTO; a SHA-256 scope binds it to the active account + endpoint without storing either raw value; expired windows and snapshots over 7 days old are rejected) → live fetch (3 attempts, backoff, 10s timeout) → on 401 re-read auth.json once and retry when either token or account changed → still-401 falls back to JSONL or surfaces `.unauthorized` → transport errors fall back to `CodexRateLimitReader`'s session-JSONL scan. Refreshes are single-flight and cancelled when the panel closes; a fallback replaces an existing `.ok` snapshot only when its `dataAsOf` is newer, so degraded reads cannot make displayed usage go backwards. The JSONL scan is thus entirely off the happy path — it runs only on fetch failure.
- **Claude delegates the live read to a Claude Code binary.** `ClaudeUsageProbe` spawns one (`--print --safe-mode --no-session-persistence --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools "" --output-format stream-json --input-format stream-json --verbose --settings <ClaudeNonessentialTraffic.probeSettings>`), sends `initialize` then `get_usage` over the stdio control protocol, and parses the reply: `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` (each with `utilization` + ISO-8601 `resets_at`), `extra_usage`, and `subscription_type` for the plan badge. The request **must** carry `skip_behaviors: true` (`ClaudeUsageProbe.usageRequest`; approved by the maintainer on 2026-11-06 under the Architecture Approval Gate, since it changes which local data the child process reads): without it Claude Code first scans every local transcript touched in the last seven days for the `/usage` "what's contributing" analysis and answers only after that scan. The card never reads it, and on heavy accounts with Claude Code 2.1.299+ the scan alone can outlast the 8s per-candidate budget, leaving every probe timing out and the card on the cache — stale numbers, no plan badge (issue #57). Claude Code documents the flag for usage meters; the quota fields are built the same way with or without it. `subscription_type` is shown as reported: Claude Code still answers `max` for accounts Anthropic renamed from Max 20x to Ultra (2026-10-30) — the tier is only in `rateLimitTier`, which `get_usage` does not return — so the badge says Max until Claude Code reports `ultra`; never infer Ultra from a missing 5h window (unverified Ultra accounts keep one). ~2.5s, zero tokens on a subscription login (the app never sends a prompt; a third-party provider setup may cost a model-availability check, below), no keychain prompt — the binary reads its own credentials. Binary discovery goes `VIBE_USAGE_CLAUDE_BIN` → user-installed CLI (`~/.local/bin/claude`, `~/.claude/local/claude`, the Homebrew prefixes, then every `$PATH` directory — `$PATH` matters because `QuotaProductRegistry` already counts a PATH `claude` as 「已检测」, so omitting it left version-manager installs (nvm/fnm/volta shims) detected but never probed) → the newest copy Claude Desktop manages (`~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`; older retained Desktop versions are not retried). The Desktop bundle is deliberately **last**: it exists to cover machines with no CLI at all and must not take over on machines that have one. Candidates share one 25s overall budget and each gets at most 8s, so an executable that hangs cannot multiply the loading time. Stdout uses cancellable async line iteration; panel close/toggle-off also terminates the active `Process`, so neither a blocked read nor a descendant retaining the pipe can hold the refresh open. **The probe keeps the user's nonessential traffic off and still reads the quota (network-privacy principle, rules 4 and 6, 2026-11-24).** Read from Claude Code 2.1.330 and measured with a host-logging proxy: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` blocks every request Claude Code calls nonessential, the usage read included (with it on, `get_usage` answers only from Claude Code's own `cachedUsageUtilization` snapshot — reused for 60s, served as a fallback up to 1h — and nothing refreshes that snapshot, not even the user's own sessions). So the probe clears that master switch for its own process only — every feature with a switch of its own stays off, and what the master switch alone would also have stopped is listed below — and turns on every separate off switch Claude Code has (`ClaudeNonessentialTraffic.quietEnvironment`: fast mode — which also skips the organization's fast-mode status request —, telemetry, error reporting, auto-updater and updates, bug/feedback commands and survey, GrowthBook and feature flags, vitals, model catalog, installation checks, official-marketplace auto-install, `DO_NOT_TRACK`), in the child environment and in an in-memory `--settings` (`probeSettings`; flag settings outrank the user's files, which Claude Code re-applies after spawn). Measured with Claude Code 2.1.330, a valid login and a proxy variable set: the proxy saw connections to `api.anthropic.com` only, which the code maps to the usage read plus `/api/claude_cli/bootstrap`, which Claude Code requests at every start and no separate switch covers. From the code, Claude Code may also, on the same host and account: preconnect (`HEAD /api/hello`, skipped when a proxy variable is set), refresh the account profile when its copy is missing or over a day old, read a Team / Enterprise organization's remote settings and policy limits, refresh an eligible Pro / Max account's invite eligibility (personal plans included) when its cached copy is missing or stale; and when the access token has expired it renews it with its own login service (`platform.claude.com`). OpenTelemetry export that the user or the organization configured explicitly is their own setting and is left as it is. In that measurement, with the master switch on, Claude Code made no request at all. These are observations for a claude.ai subscription login with a proxy variable set; a custom `ANTHROPIC_BASE_URL`, an explicitly enabled gateway model discovery or OpenTelemetry export send elsewhere as the user configured, and `CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION` turns the per-key union below off. Tried and not taken: a host-filtering local relay cannot tell those requests apart (one host); a TLS-terminating relay could, but would put the user's Claude OAuth bearer through our process in plaintext; Claude Code keeps no fresh quota on disk while the switch is on; `--bare` never reads the keychain. A Claude Code set up for a third-party provider (Bedrock, Vertex, …) has no plan quota (`rate_limits_available: false`), and while starting it may first check model availability with the user's cloud account — `messages.create` with a fixed `.` and `max_tokens: 1`, possibly for several candidate models, which may cost a little usage; the probe does not try to detect that setup (matching Claude Code's boolean parsing and settings precedence for those keys is too easy to get wrong, and a false match would hide a subscription user's quota), so this is disclosed instead, as it was on `main`. An organization's managed settings outrank `--settings`: when they set the switch — key by key, a forced `com.anthropic.claudecode` profile that sets it, else `/Library/Application Support/ClaudeCode/managed-settings.json` merged in order with `managed-settings.d/*.json` (`ClaudeNonessentialTraffic.isForcedByPolicy`, only that key read, the rest dropped) —, the coordinator starts no quota probe (copying diagnostics still runs `claude --version`). A valid Claude Desktop record (offline, outside that policy) still shows, with `LiveFailure.claudeBlockedByPolicy` (「组织策略关闭了 Claude Code 非必要流量」) as the live read's reason; Claude Code's own snapshot predates the policy and is not painted. Without a Desktop record the card is `.noData` with `EmptyReason.nonessentialTrafficDisabled` (「组织策略关闭了 Claude Code 非必要流量 · 无法读取」, Settings 「已禁止」), no retry. Checked on every refresh; `ClaudeUsageProbe.fetch` repeats the check. A managed `env` is merged key by key across sources in Claude Code 2.1.330 (its schema: "env keeps its own per-key union", whatever `managedSourcesBehavior` says), so for this one key the highest source that sets it decides — a forced profile, then the files merged in order — and a source that sets only other keys leaves it to the next. Server-managed settings from the claude.ai console are invisible here; with those the probe runs and Claude Code may answer from its own recent snapshot or without windows. The shared pause vocabulary (#190) names the policy state `vendorTrafficDisabled`. The probe never writes Claude's settings files and never passes `--bare` (that skips the keychain). `CLAUDE_CONFIG_DIR` is preserved. `rate_limits_available: false` (API key / Bedrock / Vertex) is a permanent answer and becomes a `.noData` card with neutral copy — never a retry loop; a null `rate_limits` on a subscription account is retryable and falls back to cache.
- **This replaced the statusline capture hook, which could never work for Claude Desktop.** Claude Code builds the statusline payload inside its *terminal* render loop; Desktop hosts sessions through the SDK and never invokes a `statusLine.command`, so Desktop-only users saw a permanently empty card while their token stats worked fine. `LegacyStatuslineRetirement` hands the `~/.claude/settings.json` edit back on launch (restoring the command saved in `~/.vibe-usage/statusline-original`, else removing the key) and deletes the generated wrapper/sidecar/capture files; it deliberately keeps `settings.json.vibe-bak`, the only copy of the user's pre-edit settings. `claudeRateLimitEnabled` is now a plain display toggle defaulting to on, like Codex — a one-time migration flips the old stored `false` (which usually just meant "never clicked 启用") to on. Keychain + `api.anthropic.com/api/oauth/usage` remains a dead end: that ACL binds to the app's code signature, so every re-sign re-prompts (removed in 87e1061).
- **Two on-disk caches paint the Claude card instantly.** `ClaudeUsageCache.configSnapshot()` reads `cachedUsageUtilization` from `~/.claude.json` — written by any Claude Code session including the ones Desktop spawns, and by our own probe, but *not* by Desktop's Electron process (which polls `/api/organizations/{org}/usage` instead). It carries `resets_at`, so it can drive the reset countdown; the account is verified against `oauthAccount.accountUuid` in the same file, already-reset windows drop their `windowDuration`, and a 7-day hard bound applies. `desktopHistorySnapshot()` is the last resort: Desktop's `plan-usage-history.json` (30-day ring, 4.5-min append throttle, keys `fh`/`sd`/`so`/`sn`) has **no `resets_at` at all**, and the 5-minute poll feeding it is gated on the user enabling Desktop's own menu-bar usage indicator — so freshness cannot be assumed and a sample is dropped once it is older than the window it describes.
- **Freshness is tracked, not printed.** `ProviderRateLimit.dataAsOf` records when the numbers were produced (live fetch ≈ now; Codex JSONL event timestamp; Claude's own `fetchedAtMs` / Desktop's sample time) and still decides which snapshot wins a refresh race. The card shows no 「数据截至 N 分钟前」 footer (removed 2026-10-24 by maintainer decision: an age line under every card read as noise); the only line under the meters is the failed-live-read note described below, which appears only while the live read is failing; 「重置券 ×N」 sits beside the provider title on both platforms. `isCodexRateLimitRefreshing` / `isClaudeRateLimitRefreshing` on AppState drive a mini spinner in the card header while a refresh is in flight (Codex ~1s of network latency, Claude ~2.5s of subprocess round trip).
- **"Not enforced" vs "no data" for the Codex 5h window.** The endpoint reports enforced windows exhaustively, so an absent/null 5h window there means OpenAI switched the limit off (2026-07-12 for every paid plan; restored for Plus/Business later, still off for Pro as of 2026-10). Plus/Business show their real 5h row. `fiveHourNotEnforced`, or a Pro/ProLite plan, renders the reserved 5h slot as 「不限额」 (maintainer decision 2026-10-24). A present but malformed window makes the entire live response unparseable and triggers fallback; it is never treated as proof of non-enforcement. A non-Pro JSONL snapshot can't make that claim (a missing window may just mean idle >5h), so its placeholder stays 「近 5 小时无活动」.
- Display: a **product tab strip** over a horizontal row of 240pt cards (two per screen, the rest scrolls sideways). The strip is the row's index in *both* directions: clicking a tab scrolls the row to that product (`ScrollViewReader.scrollTo(anchor: .leading)`), and scrolling the row activates the tab of the card that reached the leading edge (`QuotaCardOffsetPreferenceKey` publishes every card's `minX`; the one nearest zero wins, then `selectQuotaTab` persists it). Three tab states, one per monitoring/health combination: monitoring **off** = grey (45% opacity), no card at all, and clicking it opens Settings (that is where monitoring is turned on); monitoring **on but the last read settled on anything other than `.ok`** = full brightness plus the amber warning dot (`QuotaUtilizationPalette.warning`, suppressed while a refresh is in flight) so the tab points at the card that explains itself; monitoring **on and `.ok`** = plain mark unless a network pause accompanies the meters. Tabs and card headers draw the same monochrome provider marks as Settings (`ProviderIcon` → `ProviderGlyph`, maintainer 2026-11-20: 「这里的提供商图标和设置里的统一样式也对齐一下吧」); the former colored app-icon PNGs are gone. Because only enabled products own a card (`AppState.quotaCardProviders`), an all-off selection leaves the section at the icon row with nothing under it instead of a row of placeholders. The strip lists the whole catalog in the persisted order (`QuotaSelectionPreferences.orderKey`): monitoring-on products first, monitoring-off ones after them, then a bare gear icon that opens the Settings 订阅配额 page (switches, per-product status, ZCode key, 「重新检测」, drag order) — an icon, not a chip, outside the drag order. A grey tab opens the same page and flashes that product's row (ZCode without a key also opens its key block). Tabs are draggable: the stored order *is* the render order (enabled group first), so a cross-group drop normalizes back into the dragged product's own group and dropping past the last tab means the end of that group. Rows share the tallest card's height, so a provider with fewer meters still aligns with its neighbour. Card states: `.ok` renders meters; a cold `.noData` stays visible as 「正在读取订阅配额…」 while that provider's refresh is in flight (both legs now have real latency); a settled `.noData` shows the reason available to it (see below); `.retryableError` (and `.unauthorized`) keep the provider card plus a retry button. Cards accept provider-neutral meters, render the first three (`RateLimitCardView.compactMeterLimit`), and fold the rest behind a clickable 「另有 N 项」 line that expands the card in place instead of hiding those windows.
- **Empty cards (#190).** `RateLimitCardView.emptyStateText` shows the source's `emptyReason` first, then its typed `liveFailure`. Codex reports 「额度已用满 · 等待重置」 for an exhausted window and 「没有生效的额度窗口」 for an answer with no enforced window (including a null `rate_limit`, while a missing key still fails parsing). Claude's `rate_limits_available: false` gives 「Claude Code 未使用订阅登录」 (maintainer 2026-11-26): Claude Code answers it for a token in its `settings.json` `env` (a gateway such as Magpie, or a relay), an API key, a cloud provider, and no sign-in at all — a token wins over a stored claude.ai login, so a subscriber lands here too, and 「当前登录方式不含订阅额度」 read as "no subscription". Other products keep that general line for the same reason. CLI schema v1 accepts `limitReached`, `noWindow`, `notEntitled`, `sessionWithoutPlanLimits`, `periodEnded` and `noLocalRecord`. A reason is set only by a source that can know it (the live Codex endpoint, Claude's definitive answer, the CLI's structured field); session JSONL and disk caches leave it nil, so a card never invents 「已用满」. The last two give Grok and Antigravity their own next-use or next-read hints. Without a known reason, a placeholder (`fetchedAt == nil`) says 「尚未读取」. A completed read says 「没读到额度，原因未知」 if detected locally, otherwise 「未检测到安装」. `.disabled` remains for pre-0.5.7 snapshots.
- **Live failures and pauses (#190, approved 2026-11-25).** `QuotaCLIBridge` maps the CLI's closed `failureReason` vocabulary and optional numeric `httpStatus` to `ProviderRateLimit.LiveFailure`. Native readers use `RateLimitFetchError.liveFailure`; provider transport errors conform to `RateLimitFetchError`, whose shared classification keeps the coordinator independent of provider-specific error enums. Each producer stamps `ProviderRateLimit.source`: `.live` (Claude probe, Codex / OpenCode Go endpoint, CLI `source: "live"`), `.cache` (Codex's last-live snapshot file, Claude's `cachedUsageUtilization`, CLI `source: "cache"`), `.desktopRecord` (Claude Desktop history), `.localLog` (Codex session JSONL, CLI `source: "local"`). Unknown reason codes are treated as absent. The card uses fixed copy from `RateLimitCardView` and never displays CLI `message`, stderr or response bodies (they can carry paths, account names or credentials); the only interpolations are a product name where a place must be named and an HTTP status number. A retryable card shows its reason (fallback 「暂时读不到额度」), 「来源：实时读取」 and a retry for that provider. Claude reports the last candidate's failure on the card and per-candidate results in diagnostics.
- An `.ok` result with a failure reason keeps its meters and names their source (缓存 / 本地日志 / Claude 桌面端记录 / 上次实时读取) and the specific reason below them. A cached CLI answer without a known code keeps 「实时读取失败」. A network `pauseReason`, including `proxyUnsupported`, shows the pause with no retry button. A pause can accompany local meters (#189), retaining the source line, amber tab dot and 「已暂停」 in Settings. Only the three egress pauses are retried at every panel open; `proxyUnsupported` and every other reason keep the normal interval.
- CLI `missing_credentials` prompts for login or the selected regional ZCode key. `unauthorized` and `expired_credentials` prompt to log in again or replace the invalid key. Antigravity's `programNotFound` (also a legacy CLI's `missing_credentials` without a known code) shows 「请安装 agy 或 Antigravity」. Rejected Antigravity credentials show 「请在 Antigravity 中登录」. Keep card and Settings wording aligned with the Windows app.
- Terminology: code stays on `RateLimit` (matches the `rate_limits` field both providers return); user-facing copy uses 「订阅配额」. Selector items use the product display name plus local status. Settings no longer shows where each product's data comes from — the 「数据来源」 column, including the 「Claude Desktop」 note for machines with Desktop but no CLI, was removed by the maintainer on 2026-11-20 (「订阅配额里去掉数据来源那一列。」). The launch-time `AppState.claudeUsesDesktopBundledCLI` flag that fed it went with it; `ClaudeUsageProbe.primarySourceKind()` itself is unchanged.
- Claude's `modelScopedMeters` uses the same raw rows from live `rate_limits.limits` and cached `utilization.limits`. Read `scope.model.display_name` and `percent` for `group == "weekly"`. The group defines a seven-day window. The optional `resets_at` accepts Unix seconds or an ISO 8601 string. Claude Code filters its live `model_scoped` projection by name. Keep model meters separate from the classic card's typed 5h, 7d, Opus, Sonnet and extra rows.
- A present `limits` field supplies the complete list, including an empty one. Only an absent field permits carrying a previous live value with a future reset for the same account. Match the existing `initialize` reply to the config cache using a process-local hash of email and organization (empty organization means absent). The cache also requires matching cached and active account UUIDs for this comparison. Desktop history provides no account proof. No additional request, profile read, app-owned disk cache or diagnostic field is involved.
- `CodexUsageAPI` maps a post-reload 401 to `.unauthorized`, and the card renders a re-login hint with a retry button.
- **Codex JSONL staleness policy (stricter than Claude's).** Codex's `rate_limits.primary/secondary.resets_at` is anchored to a true rolling window, so a `resets_at` already in the past proves that window has rolled over and the snapshot's `used_percent` is from the *previous* window. `CodexRateLimitReader.parseWindow` drops any such slot (per-window — 5h and 7d expire independently), and `read()` returns `.noData` if both slots are expired so the card shows its neutral "nothing read yet" line instead. Without this filter the reader would display a stale percentage indefinitely (e.g. an 8% reading hanging around 12 days after that window's `resets_at`). The Claude reader is intentionally more lenient — it keeps `used_percentage` and only suppresses the elapsed-time bar when stale — because Claude's payload has no equivalent "this window has provably rolled" signal; staleness there just means Claude Code is idle (and the 「数据截至」 footer note communicates the age).
- **The rollout walk is memory-bounded (2026-10-09, user feedback: 420 MB in Force Quit).** `CodexRateLimitReader.scan` walks a rollout backwards in 256 KiB `pread` chunks and returns the first (newest) `rate_limits` event, instead of `String(contentsOf:)` + `split` over the whole file. A long Codex session appends for hours — the biggest rollout on this machine is 469 MB — and the whole-file read cost ~2× the file size *in live memory* that stayed resident in the malloc arena after the call (measured: 943 MB footprint for 469 MB, and `FileHandle.read(upToCount:)` alone reproduces it because its footprint tracks the bytes read). The chunked walk measures 2 MB on that same file, in a full walk and in the shipped read path, and returns identical values for all 405 real rollouts on this machine. End-to-end A/B with one 400 MB rollout in the shipped bundle (popover opened, isolated `CODEX_HOME`): 0.7.2 peaks at **863 MB**, 0.7.3 at **38 MB** — the empty-fixture control is 37 MB, so the path now costs nothing measurable. Keep the POSIX read — an equivalent loop over `FileHandle` reintroduces the file-sized footprint. Peak memory is one chunk plus the longest single line (real tool-output lines top out near 9 MB), and `Tests/VibeUsageTests/CodexRateLimitReaderTests.swift` pins the chunk-boundary cases (event behind the tail chunk, line straddling a boundary, line longer than a chunk, decoy line with the key but no `token_count`).

### Settings Window
Settings uses a raw `NSWindow` via `SettingsWindowController`. The SwiftUI `Settings` scene stays as a placeholder to satisfy the `App` protocol; the actual settings surface is managed directly so it behaves consistently alongside the custom dashboard panel.

**Layout (finalized design, maintainer 2026-11-20 「定稿」; drawings in the workspace's `交接笔记/设置页设计-Fable/C完整稿/`).** 700 × 460, may be dragged taller but never wider; only the close button is live. The window is pinned to `darkAqua` (「只做深色」) and its content runs under a transparent title bar (`fullSizeContentView`), so the 168 pt sidebar reaches the top edge; the window buttons are moved to the design's spot (centered 24 pt down, 22 pt in) and re-placed on resize and key changes. Colors, type and control metrics live in `SettingsTheme` — fixed dark values, not system colors — and the controls are drawn (30 × 18 switch in the panel green, 24 pt buttons, segmented pills, 26 pt inset fields) so they match the design in every window state. Use explicit `Rectangle()` / shape backgrounds: on macOS 26+ a bare `.background(Color)` on some views is drawn with rounded corners.

The sidebar has five pages, in the maintainer's order: **通用** (a preview area on top — a slice of a screen: the user's own desktop picture with the transparent macOS 26 menu bar on it at this Mac's real menu-bar height, our status item and the clock, text dark over a bright picture — then one card for 菜单栏显示费用 / 菜单栏显示 Token and one for 开机自启动 / 在 Dock 中显示; the preview's status item is the real `MenuBarLabel` fed by `MenuBarLabel.lines(for:)`, so it shows exactly what the menu bar shows — the icon alone until there is usage, cost and Token stacked in two lines when both are on; maintainer 2026-11-20 rejected putting the preview inside or between the switch rows, then a plain grey desktop) → **订阅配额** (one table of every product) → **数据同步** (API Key + 重新链接 / 链接 with the device code inline, 同步 status with the last ten runs from `SyncHistoryStore` as bars, 重置配置 with its confirmation) → **数据目录（高级）** (额外 Codex Home with a clear button, folder picker and 保存并同步; 隔离运行时目录 per source) → **关于** (laid out like CodexBar's About page, which the maintainer pointed to on 2026-11-20: a centered identity card with the app icon, name and 「版本 x (build)」; then group titles (`SettingsSectionTitle`, also used for 隔离运行时目录) over an 更新 card (version + 「检查更新…」), a 诊断 card (复制诊断信息 with what was copied shown underneath; 导出诊断日志 tagged 测试版 in test builds only) and a 链接 card whose whole rows open the CLI repository, the app repository and the configured VibeCafé site (production defaults to vibefriends.com) in the browser (`SettingsLinkRow`, `SettingsLinks`; GitHub mark from Simple Icons, CC0; SF Symbols globe); a 「© 2026 VibeCafé · MIT 许可证」 line closes the page). The sidebar carries a single mark: a red dot next to 数据同步 after a failed sync while an account is linked (it clears with 「重置配置」, like the 同步 row), visible from every page — no enabled count, no green dot, and 数据目录 without its 「高级」 chip, which sits after the page title instead (maintainer 2026-11-20, 「按这三点改」). A page taller than the window scrolls on its own; the sidebar never moves.

**订阅配额 table.** Columns 工具 / 状态 / 面板卡片 with monochrome marks (`ProviderGlyph`: Lobe Icons path data, MIT, license in `Resources/ThirdPartyNotices.txt`); the panel's tab strip and card headers draw the same marks through `ProviderIcon`. Rows follow `AppState.quotaTabOrder`: enabled products first, the rest under 「未开启」. The 状态 column and the panel tab’s amber dot share `AppState.quotaWarningSnapshot`. `SettingsQuotaStatus` shows a short reason in amber. Login and installation use 「需登录」「已失效」「需打开」「需 Key」「Key 无效」「未安装」「需升级」. Empty states use 「未订阅」「不适用」 (Claude: 「未用订阅登录」)「已禁止」「已用满」「无窗口」「待更新」「无记录」「未读取」「无数据」. Network pauses use 「已暂停」. Failed reads use 「超时」「连不上」「接口报错」「数据异常」「读不了」「不支持」「续期失败」「无响应」「启动失败」「缺 Node」「CLI 出错」 or 「失败」. `.disabled` shows 「未启用」 and `.error` shows 「出错」 in red. With no warning snapshot, the row shows 已检测 / 未检测到, or 「需 Key」 for an unconfigured ZCode key. Each row ends with a drag handle; a drop goes through `QuotaReorder` (stays inside the dragged product's group) into the panel's own `moveQuotaProduct`, so Settings and the panel share one stored order (`quotaProductOrder`). ZCode has a disclosure triangle at the row's start and opens into a rounded block on one line: region segments, the key field, 保存; with a key saved it shows 「✓ Key 已保存」 + 更换 / 移除. Saving never turns the switch on; removing turns it off (`AppState.storeZCodeAPIKey`); turning the switch on does not open the block. No explanatory sentences on the page (maintainer, 2026-11-26: 「写这么多防守性的文字干什么」 — the privacy note under the table, the egress option's grey line and the Antigravity note were removed; their facts live in the README). Under the table a 「隐私保护」 group holds one row, 「没检测到代理时」, with a native pop-up menu like System Settings' 「显示滚动条」 (`EgressSettingsCard`, maintainer 2026-11-25: 「改成三选一」 after the two switches read as unclear): 「自动判断（推荐）」 / 「暂停读取」 / 「照常读取」. (Google's forum and FAQ say wrapping `agy` in a third-party app is not supported on personal plans; that is stated in the README, not on the Antigravity row.)

**The preview's wallpaper (maintainer-approved 2026-11-20, 「就这么改」).** `MenuBarWallpaper` reads `NSWorkspace.desktopImageURL(for:)` of the Settings window's screen (else the main screen) and decodes only a small thumbnail of the top strip (ImageIO, primary frame of a dynamic picture). It never reads a picture where reading could raise a privacy prompt — Desktop, Documents, Downloads, a home-folder `Dropbox…` folder, a Photos library, `/Volumes`, and all of `~/Library` except `Application Support/com.apple.mobileAssetDesktop` (iCloud Drive, cloud-provider folders, other apps' containers, Full Disk Access data) — checked before and after resolving symlinks; no screen recording or screenshot API. Unreadable, not an image, or protected → a code-drawn gradient (`MenuBarWallpaperFallback`); no wallpaper file ships with the app. The picture lives only in the preview's view state (read on appear, released with the page or window); it is never cached to disk, logged, put in diagnostics or uploaded. Promotional screenshots must use the fallback gradient.

**Entry points and state.** The popover's 「设置」 opens the last page (`SettingsNavigation`, persisted as `settingsLastPage` in the app's own preferences — a UI-state key nothing else reads; the first open is 通用). The strip's gear opens 订阅配额; a grey tab opens 订阅配额 and flashes that row. `SettingsModel` holds every page's in-flight state (re-link, drafts, save results) per window, so switching pages loses nothing; a newly opened window reloads from disk.

**Settings copy stays terse.** A label is the shortest direct word (「区域」, 「保存」, 「移除」), and an explanation belongs behind the control it explains or nowhere at all. Numbers, dots and small previews carry state instead of sentences. A new setting joins an existing page (or, for a new subject, a new sidebar page) rather than growing a page with prose.

### ActivationCoordinator
`ActivationCoordinator` follows the persisted `showInDock` preference: `.regular` with the bundled Dock icon when visible in Dock/Cmd-Tab, `.accessory` when hidden. Settings temporarily promotes the app to `.regular` so it keeps a main menu and Cmd-Tab entry while the Settings window is open. It remains the single place that reconciles activation policy, which prevents future popup/settings transitions from fighting each other.

It also emits `onSettingsVisibilityChange`, which `MenuBarController` uses to lower the popover panel from `.popUpMenu` to `.normal` while Settings is visible (so standard z-ordering lets a click on Settings bring it forward). Sparkle modal visibility flows through `updateModalVisibilityDidChange(_:)` for the same reason, and `canPresentDashboardForAppActivation` blocks Dock/Cmd-Tab dashboard presentation while Settings or Sparkle dialogs are active.

### Menu-Bar Click Handling
The status item renders SwiftUI via `NSHostingView` inside the `NSStatusBarButton`. A vanilla `NSHostingView` swallows the button's action — use `PassthroughHostingView` (defined inside `MenuBarController.swift`), which overrides `hitTest(_:) -> nil` (routes events to the button), `acceptsFirstMouse(for:) -> true` (first click registers when the app is inactive), and `mouseDown`/`mouseUp` forwarding to `superview` (fallback when SwiftUI's responder chain receives the event instead of the button).

### Popover Panel Sizing
`ensurePanel()` attaches `NSHostingView` as a subview of `panel.contentView` pinned by autolayout — **not** as `panel.contentViewController`. The controller path breaks in opposite directions across macOS versions: on Sequoia (15.x) it collapses the panel to 0×0 (intrinsic size read before first layout is (0,0)); on Tahoe (26.x) the same content-size bridge feeds a reentrant layout loop that stack-overflows `ViewGraph`'s renderer. `sizingOptions = [.minSize, .maxSize]` (macOS 13+) drops the default `.intrinsicContentSize` so SwiftUI is never probed with a 0×0 proposal. Panel size comes from the initial `contentRect` + autolayout pinning; nothing else drives it.

### Auto-Updates (Sparkle)
- `SPUStandardUpdaterController` initialized in `UpdaterViewModel`
- `UpdaterDelegateProxy` (NSObject conforming to `SPUUpdaterDelegate`) publishes `availableUpdate: SUAppcastItem?` on `didFindValidUpdate`, clears on `didNotFindUpdate` / `userDidMake(.install|.skip)`, keeps banner on `.dismiss`
- Popover footer renders a "发现更新" button when `availableUpdate != nil`; click re-invokes `checkForUpdates()` → Sparkle's standard install dialog
- Feed URL: `https://github.com/vibe-cafe/vibe-usage-app/releases/latest/download/appcast.xml`
- Ed25519 public key in `Info.plist` (`SUPublicEDKey`)
- Ed25519 private key in developer Keychain (used by `generate_appcast`)

## Data Model

```swift
struct UsageBucket: Codable, Identifiable, Equatable {
    let source: String              // Tool name: "claude-code", "cursor", etc.
    let model: String               // Model: "claude-sonnet-4-20250514", etc.
    let project: String             // Project folder name
    let hostname: String            // Machine name
    let bucketStart: String         // ISO8601 UTC timestamp
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let estimatedCost: Double?      // Server-calculated cost (nil if model unmatched)

    var computedTotal: Int           // inputTokens + outputTokens + reasoningOutputTokens + cachedInputTokens (matches web "总 Token")
    var dayKey: String               // "yyyy-MM-dd" from bucketStart
    var hourKey: String              // "yyyy-MM-ddTHH" from bucketStart
}
```

Token aggregation conventions (aligned with the web Vibe Usage page):
- Popup summary "总 Token" card → `computedTotal` (includes cache reads, matching web "总 Token")
- Popup summary "缓存 Token" card → `cachedInputTokens` (cache reads only)
- Trend chart token mode → stacked output, input, and cached segments; reasoning tokens are folded into output.
- Distribution charts token mode → `computedTotal`
- Menu-bar token line → `computedTotal`
- `estimatedCost` already accounts for cache reads (server-side, at `cacheReadMtok` rate)

Display names and families (server-supplied):
- Raw `source` / `model` ids stay the source of truth for API, uploads and tool/project/host filters; only the dashboard labels change.
- **The app keeps no id→name table and no matching rules.** `/api/usage` returns a `names` object (`sources`, `models`, `modelFamilies`, `families`) for the ids that response contains, and `AppState.toolName` / `modelName` / `modelFilterGroups` read it. An id the server could not resolve has no entry and renders exactly as reported — never guessed.
- That is deliberate: the rules and the models.dev snapshot live once, in `vibe-cafe` (`apps/web/src/lib/usage-display-names.ts` + its generated snapshot). This app, the Windows app and the dashboard all read the same fields, so they cannot disagree — three hand-synced tables is what `kiki` had to be added to before this.
- Models resolve to one official name per underlying model, so reasoning-effort, router-prefix and context-size variants (`gemini-3.8-flash-high`, `kimi-code/k3-256k`) merge. The model filter and the model distribution chart group by this display name; the filter stores display names, so selecting one selects every id behind it.
- A suffix is stripped only when what remains is a known model (`qwen3-max` keeps its name). Family grouping uses the server's rows, in the server's order, with unplaced names under 其他.
- A server that predates the field decodes fine (`names` is optional): everything falls back to raw ids and the model filter has a single 其他 group.
- `vibe-cafe` owns the snapshot's refresh (`apps/web/scripts/generate-model-display-names.mjs`); this repo has nothing to regenerate.

## Styling Conventions

The panel and Settings share `appState.interfaceStyle.current` (`.modern` / `.classic`). Settings can offer the choice when `canSelect` is true and apply it with `select(_:)`. Debug builds accept `VIBE_USAGE_FORCE_INTERFACE_STYLE=modern|classic` for rendering. A forced style lasts for that run and never writes a preference; it can still be switched in memory (`canSelect` is true), so renders and manual checks see the Settings row. The copied diagnostic summary includes the effective style as 「界面样式：新版」 or 「界面样式：经典」 only where the style can be chosen (external-test builds, forced Debug runs, and every build once the gate opens); release builds before that keep today's report.

| Element | Color |
|---------|-------|
| Background | `Color(white: 0.04)` |
| Card background | `Color(white: 0.09)` |
| Borders | `Color(white: 0.16)` |
| Primary text | `.white` |
| Secondary text | `Color(white: 0.63)` |
| Tertiary text | `Color(white: 0.38)` |
| Cost accent | `Color(red: 0.2, green: 0.8, blue: 0.5)` |
| Card corner radius | `4` |
| Card border width | `1` |

- Font sizes: 14pt bold titles, 11-12pt labels, 9-10pt secondary, monospaced for numbers
- The Settings window has its own fixed dark palette and type scale (`SettingsTheme`: content `#1e1e1e`, sidebar `#181818`, cards `#292929`, 15 / 13 / 12 mono / 11 pt), taken from the finalized design; the table above is the panel's
- All UI text in Chinese
- **Dynamic long names (project / hostname) truncate in the MIDDLE, with a hover tooltip**: `.truncationMode(.middle)` + `.help(fullName)`. Same-prefix projects (`org/repo-a` vs `org/repo-b`) only differ at the tail, so tail truncation makes them indistinguishable — this was real user feedback (2026-08). The convention is cross-surface: web `/usage` and `vibe-usage-windows` implement the same behavior; new name-displaying UI in any of the three should follow it.
- Window levels: Settings uses default `.normal` (so Sparkle update dialogs can sit above it); the popover panel uses `.popUpMenu` normally, lowered to `.normal` while Settings is visible

## Release Process

### 1. Bump Version — THREE locations, all required

| File | Field | What |
|------|-------|------|
| `VibeUsage/Models/AppConfig.swift` | `static let version` | Display version (e.g. `"0.2.3"`) |
| `VibeUsage/Info.plist` | `CFBundleShortVersionString` | Must match AppConfig (e.g. `0.2.3`) |
| `VibeUsage/Info.plist` | `CFBundleVersion` | Build number, **must increment** (e.g. `4`) |

`CFBundleVersion` is the integer Sparkle compares. If you only bump the display version but forget this, Sparkle will not detect the update.

`./scripts/check-version.sh` (run automatically at the top of `build-app.sh`) enforces that:
- `AppConfig.version == CFBundleShortVersionString`
- `CFBundleVersion` is a plain integer
- `CFBundleVersion` strictly increased vs. the previous `v*` git tag

The last rule fails only a release: the script run standalone, or a
`build-app.sh --notarize` build without `--external-test`. Every other
`build-app.sh` build (local, ad-hoc, external test, rehearsal) passes
`--non-release` and gets a warning instead, because between releases `main` still
carries the last tag's build number. A tag whose build number cannot be read is
treated the same way.

Commit and push the bump before building, so the release is cut from a commit that
contains it:

```bash
git add -A && git commit -m "bump version to X.Y.Z" && git push
```

### 1a. Move the Bundled Node to the Newest 24.x Patch

Before each release, check https://nodejs.org/dist/index.json for a newer `v24.*`. If there is one, update all three lines of `scripts/bundled-node.env` from that version's `SHASUMS256.txt` (`node-v<version>-darwin-arm64.tar.xz` / `-x64.tar.xz`) and commit it with the release. `fetch-node.sh` refuses a tarball whose SHA256 differs from either source. A Node release of its own is warranted only for a high-severity fix in code the CLI uses (HTTPS client, TLS, zlib, file access). Move to the next LTS major before 24's end of life (2028-04-30), after the CLI's CI covers it, together with the Windows app.

### 2. Model Names Need No Release Step Here

Model display names and families are resolved by the server (`vibe-cafe`) and shipped
with each `/api/usage` response, so this app has no snapshot to refresh and nothing to
commit. A newly released model simply renders as its raw id until the server's snapshot
is regenerated — a stale server snapshot never shows a *wrong* name.

Release the server's snapshot from `vibe-cafe`:

```bash
node apps/web/scripts/generate-model-display-names.mjs   # fetch models.dev, review the diff
```

### 3. Build + Sign + Notarize

```bash
./scripts/build-app.sh --universal --notarize
```

Produces in `dist/`:
- `Vibe Usage.app` — signed + notarized app bundle
- `VibeUsage.dmg` — distribution disk image (user download)
- `VibeUsage.zip` — update archive (Sparkle downloads this)

### 4. Generate Appcast

```bash
curl -fL -o dist/appcast.xml https://github.com/vibe-cafe/vibe-usage-app/releases/latest/download/appcast.xml
./scripts/generate-appcast.sh
```

Reads `dist/VibeUsage.zip`, signs with Ed25519 key from Keychain, writes `dist/appcast.xml`. The `curl` seeds the published feed so older items carry over; the script stops if the 0.7.4 (build 40) item that 0.5.3-and-earlier installs need is missing (see "Signing Identity History").

### 5. Create GitHub Release

```bash
gh release create vX.Y.Z \
  dist/VibeUsage.dmg \
  dist/VibeUsage.zip \
  dist/appcast.xml \
  --title "vX.Y.Z" --notes "changelog"
```

All three assets required:
- `VibeUsage.dmg` — users download this from the release page
- `VibeUsage.zip` — Sparkle auto-update downloads this (appcast `enclosure url` points to it)
- `appcast.xml` — Sparkle fetches this feed to check for updates

**After upload, always verify all 3 assets are present:**
```bash
gh release view vX.Y.Z
```
Network failures can silently drop assets. If an asset is missing, re-upload with:
```bash
gh release upload vX.Y.Z dist/<missing-file> --clobber
```

### Common Release Mistakes

| Mistake | Symptom |
|---------|---------|
| Forgot to increment `CFBundleVersion` in Info.plist | "X.Y.Z is currently the newest version" |
| Forgot `generate-appcast.sh` | Sparkle feed still lists old version |
| Forgot to upload `appcast.xml` to release | "An error occurred in retrieving update information" |
| Forgot to upload or dropped `VibeUsage.zip` | "An error occurred while downloading the update" |
| Forgot to upload `VibeUsage.dmg` | New users can't download from release page |
| Tag already exists from previous attempt | `gh release create` fails — use next patch version |

## Code Signing

Multiple authorized Macs can retain release capability at the same time; provisioning a second Mac does not disable the first. Readiness depends on the three credentials below, not the machine owner's name. Verify them on the actual release machine before each release. A missing or mismatched credential blocks production release on that machine; coordinate provisioning with the credential holder instead of generating a replacement Sparkle key. See `docs/RELEASING.md` for adding a release Mac while preserving the existing signing identity (clarified 2026-10-26 after a support investigation).

- **Identity**: `Developer ID Application: JIANZHONG ZHAO (8HGCD674ZS)` (since 0.7.5)
- **Notarization profile**: `VibeUsage-8HGCD674ZS` (stored in Keychain via `notarytool store-credentials`; currently an App Store Connect API key of team `8HGCD674ZS`, saved with `--key`/`--key-id`/`--issuer`)
- **Sparkle Ed25519 key**: In Keychain, used by `generate_appcast` automatically
- **Sparkle public key**: In `Info.plist` as `SUPublicEDKey`
- The build script signs inside-out: the bundled Node, Sparkle internals, then the framework, then the app bundle
- **Bundled Node** (`Contents/Helpers/node`): re-signed with `--force` under our identity (replacing the Node.js project's `HX7739G8FX` signature, whose `get-task-allow` notarization rejects), hardened runtime, timestamp, identifier `ai.vibecafe.vibe-usage.node`, and only `scripts/node.entitlements` — `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory`. Never add `get-task-allow`, `disable-library-validation`, `allow-dyld-environment-variables` or `disable-executable-page-protection`. `build-app.sh` refuses a Node that carries `get-task-allow` (or, with Developer ID, lacks `allow-jit`), then runs the app's probe, the shipped launcher and `check-cli.mjs` with this signed copy natively and, on Apple silicon, its Intel slice under Rosetta (a proxy only — no real Intel Mac in the loop). The ad-hoc fallback signs it without hardened runtime, like the rest of the bundle. Notarization covers it as part of the app; look at `notarytool log` for warnings about it.

### Signing Identity History

- Releases up to and including 0.7.4 were signed by `Developer ID Application: Yin Ming (D33463FWDZ)` and notarized with that team's `VibeUsage` profile. 0.7.5 switched to team `8HGCD674ZS` (maintainer-approved 2026-11-11) and **kept the same Sparkle key**.
- Sparkle accepts an update when either the EdDSA key or the Apple code-signing identity is unchanged, never when both change. Change the signing team or rotate the Sparkle key in separate releases, and validate the installed-app upgrade path before publishing either.
- Builds 25+ (0.5.4 and later) already have the current key, so they update to 0.7.5+ directly. Builds ≤ 24 (0.5.3 and earlier) still have the key retired in 0.5.4; for them 0.7.5+ changes both key and team. `generate-appcast.sh` therefore passes `--minimum-update-version 25`, so every item from 0.7.5 on carries `sparkle:minimumUpdateVersion` 25 and Sparkle hides it from builds ≤ 24. They take the 0.7.4 item (build 40: old team, current key) first and continue from there. Never drop that flag, and keep the 0.7.4 item in the feed: seed `dist/appcast.xml` from the published feed before generating (the script stops if build 40 is missing).
- The current certificate was issued under Apple's G1 Developer ID intermediate and expires **2027-02-01**. Releases already published keep working (timestamped and notarized), but the next release after that date needs a new Developer ID Application certificate created in the same team `8HGCD674ZS`. The designated requirement pins the team, so a same-team certificate is invisible to users. Remove the expired certificate from Keychain first, or `codesign` reports an ambiguous identity.

### Releasing From Another Mac — Mandatory Sparkle-Key Check

- The Sparkle key was rotated for `v0.5.4`. All later releases must use the private key matching the current `SUPublicEDKey` in `VibeUsage/Info.plist`; an older release Mac may still hold the retired key.
- Before every release, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p` and compare it with `/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' VibeUsage/Info.plist`. They must match before `generate-appcast.sh` runs.
- If the key is absent or mismatched, **stop**. Do not generate or rotate a key merely to make the release pass. Import the current private key from the secure backup or another authorized release Mac using `generate_keys -f <private-key-file>`.
- To provision another release Mac, export from a Mac holding the current key with `generate_keys -x <private-key-file>`, transfer it through an encrypted channel, import it, verify the public-key match, and then remove or securely archive the transfer copy. Never commit the exported key.
- Also verify that the destination Mac has the Developer ID private key and a working `VibeUsage-8HGCD674ZS` notarization profile. See `docs/RELEASING.md` for the complete migration checklist.
- A deliberate future key rotation requires explicit authorization and an update-path validation against the currently released app; it is not routine release-machine setup.

## Known Constraints

- LSUIElement apps cannot use SwiftUI `Settings` scene — must use NSWindow directly
- `swift run` skips Sparkle initialization (no Info.plist in non-bundle builds)
- Debug builds (`#if DEBUG`) use `localhost:3000` and `config.dev.json`
- The bundled Node makes the app ~240 MB larger installed; Sparkle still downloads a zip (format unchanged on purpose), the DMG uses ULMO compression (macOS 10.15+)
- **Never delete `VibeUsage/Utils/DateOrder.swift`.** Xcode 27.2's SDK marks Foundation's `Date` `<=` / `>=` `@backDeployed(before: macOS 27.2)` (swift-foundation#2230): built with it, code that compares two `Date` values with `<=` / `>=` directly (not through a generic `Comparable`, which dispatches to Foundation's own conformance) calls Foundation's copy, weakly linked, whenever the system reports 27.2 or later. Early macOS 27.2 betas (26B5086k, 26B5091g) report 27.2 but do not export those symbols, so the call jumps to address 0: 0.7.9, the first release built with Xcode 27.2, crashed (`EXC_BAD_ACCESS` at `0x0`) in `BarChartView.chartData` each time the panel opened. The file's operators shadow Foundation's for those comparisons in this module and use only `<` / `>`, so the binary imports neither; `nm -m` on a release build must show no `_$s10Foundation4DateV2leoiy…` / `…2geoiy…` import, weak or strong. A test file that `@testable import`s VibeUsage sees both declarations, so `<=` / `>=` between two dates there is ambiguous on the 27.2 SDK: compare with `<` / `>` in tests (`DateOrderTests` exercises the app's own uses instead).
