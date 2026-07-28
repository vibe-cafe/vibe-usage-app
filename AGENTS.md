# AGENTS.md

AI agent guidance for the vibe-usage-app repository.

## Repository Map

```
vibe-usage-app/                    # SwiftUI macOS menu bar app (SPM, Swift 6, macOS 14+)
├── Package.swift                  # SPM manifest (Sparkle dependency)
├── VibeUsage/
│   ├── Info.plist                 # Bundle metadata (versions, Sparkle SUFeedURL, SUPublicEDKey)
│   ├── App/
│   │   ├── VibeUsageApp.swift     # @main entry, AppDelegate lifecycle hooks
│   │   └── AppResources.swift     # Bundle.appResources helper
│   ├── Models/
│   │   ├── AppState.swift         # @Observable central state (buckets, filters, timeRange, sync)
│   │   ├── AppConfig.swift        # Version string, API URL, debug/release config
│   │   ├── UsageBucket.swift      # Codable data model (source, model, project, hostname, tokens, cost)
│   │   └── Config.swift           # Persistent config (apiKey, apiUrl) in ~/.vibe-usage/
│   ├── Views/
│   │   ├── PopoverView.swift      # Main dashboard container (520px wide popover)
│   │   ├── SummaryCardsView.swift # 5 stat cards (cost, total tokens, cached tokens, active duration, total duration)
│   │   ├── BarChartView.swift     # Custom-drawn bar chart (hourly/daily trend)
│   │   ├── DistributionChartsView.swift  # 4 donut pie charts (terminal, tool, model, project)
│   │   ├── FilterTagsView.swift   # Filter pills for source/model/project/hostname
│   │   └── SettingsView.swift     # Settings form (re-link via device flow, menu bar prefs, auto-start, updates)
│   ├── Services/
│   │   ├── APIClient.swift        # HTTP client for /api/usage (Bearer auth with vbu_ key) + unauthenticated device-flow helpers (requestDeviceCode/pollDeviceCode)
│   │   ├── SyncEngine.swift       # Orchestrates CLI sync (runs @vibe-cafe/vibe-usage via Node/Bun)
│   │   ├── SyncScheduler.swift    # 30-minute interval auto-sync timer
│   │   ├── CLIBridge.swift        # Executes vibe-usage CLI as subprocess
│   │   ├── RuntimeDetector.swift  # Finds Node.js or Bun runtime on the system
│   │   ├── UpdaterViewModel.swift # Sparkle SPUUpdater bridge + SPUUpdaterDelegate proxy (publishes availableUpdate)
│   │   ├── RateLimitCoordinator.swift # Orchestrates quota refreshes (cache-then-live for both providers)
│   │   ├── CodexUsageAPI.swift    # Live Codex usage endpoint client (auth.json token, zero-quota GET)
│   │   ├── CodexRateLimitReader.swift # Offline Codex fallback: session-JSONL scan
│   │   ├── ClaudeUsageProbe.swift # Live Claude quota: spawns a Claude Code binary, stdio `get_usage`
│   │   ├── ClaudeUsageCache.swift # Claude instant-paint: ~/.claude.json, then Desktop's usage history
│   │   ├── LegacyStatuslineRetirement.swift # One-time undo of the pre-0.5.7 statusline hook
│   │   ├── DirectoryWatcher.swift # kqueue directory watcher
│   │   ├── MenuBarController.swift # NSStatusItem + custom borderless popover panel (multi-line title, animated open/close)
│   │   ├── PopoverPanel.swift     # NSPanel subclass that becomes key for TextField input
│   │   ├── SettingsWindowController.swift  # NSWindow wrapper for settings
│   │   └── ActivationCoordinator.swift     # Centralizes NSApp.activationPolicy across popup + Settings + updates
│   ├── Utils/
│   │   ├── Formatters.swift       # Number, cost, date, time formatting
│   │   └── Log.swift              # Debug logging
│   └── Resources/
│       └── Assets.xcassets/       # App icon, menu bar icon
├── scripts/
│   ├── build-app.sh               # Build + sign + notarize pipeline (runs check-version.sh first)
│   ├── check-version.sh           # Guards AppConfig/Info.plist version sync + monotonic CFBundleVersion
│   └── generate-appcast.sh        # Generate Sparkle appcast.xml
└── dist/                          # Build output (gitignored)
    ├── Vibe Usage.app
    ├── VibeUsage.dmg
    ├── VibeUsage.zip
    └── appcast.xml
```

## Quick Commands

```bash
swift build                              # Debug build
swift build -c release                   # Release build
./scripts/check-version.sh               # Validate version sync across AppConfig + Info.plist
./scripts/build-app.sh                   # Build + codesign .app (runs check-version.sh first)
./scripts/build-app.sh --notarize        # Full pipeline: build + sign + notarize + DMG
./scripts/generate-appcast.sh            # Generate appcast.xml from dist/VibeUsage.zip
```

## Architecture

### App Type
LSUIElement menu-bar app with an optional Dock/Cmd-Tab presence. `AppDelegate` owns a `MenuBarController` that manages an `NSStatusItem` plus a borderless `PopoverPanel` (custom NSPanel) hosting the SwiftUI dashboard. We dropped `MenuBarExtra` so the status item can render multi-line text via `NSHostingView` (cost over tokens) and the panel can use a custom open/close animation anchored to the icon. When the user enables "show in Dock", `ActivationCoordinator` promotes the app to `.regular`, assigns the bundled Dock icon, and AppKit activation events (Dock click or Cmd-Tab switch to Vibe Usage) call `MenuBarController.presentPanelForAppActivation()` so the dashboard opens or foregrounds like the menu-bar item. App deactivation calls `dismissPanelForAppDeactivation()` so a Cmd-Tab away from Vibe Usage closes the dashboard again, unless Settings or a Sparkle modal is visible.

### State Management
`AppState` is `@Observable` and injected via `@Environment`. All views read from it. No Combine, no ObservableObject (except `UpdaterViewModel` which bridges Sparkle's KVO).

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
        │   ├── SummaryCardsView  # 5 stat cards
        │   ├── BarChartView      # Trend chart (hourly or daily)
        │   └── DistributionChartsView  # 4 donut charts (2x2 grid)
        └── footerBar             # Sync status, refresh, quit
```

### Data Flow
1. `APIClient.fetchUsage(range:)` fetches from `/api/usage` with Bearer token auth
2. Response decoded into `[UsageBucket]`, stored in `AppState.buckets`
3. Views compute filtered data locally: `appState.buckets.filter { ... appState.filters ... }`
4. Charts aggregate filtered buckets by time key or dimension

### Time Range (today / 24H / 7D / 30D / 90D / custom)
`TimeRange` (`AppState.swift`) has two hourly-granularity cases that look similar but mean different things — the split mirrors `vibe-cafe@f5f022b`, where the single rolling "1D" pill confused users who read it as "today" but watched the number shrink as the earliest hour rolled off.

- `.today` (UI: 「今天」) — local-midnight → now, fixed start. Only grows through the day.
- `.oneDay` (UI: 「24H」, raw value still `"1D"` for state stability) — rolling last 24 hours.
- `.sevenDays`, `.thirtyDays`, `.ninetyDays` — fixed day-count ranges.
- `.custom` — user-selected local date bounds, sent as `from` / `to` query params.

Today requests `from=localMidnight` while rolling 24h requests `days=1`. The today-cutoff is also applied client-side via `TimeRange.startCutoff` so all filtered views and the menu-bar display share the same local-midnight semantics. `BarChartView`'s hourly fill loop keys off `appState.timeRange == .today` to start at midnight (slot count grows from 1 → 24) instead of "23 hours ago" for the rolling-24h case. Every `/api/usage` request includes `tz=TimeZone.current.identifier`.

### Loading & Filtering
`AppState` distinguishes first load from refresh:
- `isInitialDataLoad` / `!hasLoadedUsageData` → show layout-matched skeleton blocks under a loading pill.
- `isRefreshingData` → keep the current dashboard visible, dim it, and overlay a small loading pill.

Time-range changes and custom-date Apply trigger a server fetch. Filter changes are local only and animate the existing summary cards, trend bars, and distribution charts without refetching.

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

### Sync Pipeline
1. `SyncScheduler` fires every 30 minutes (background upload + fetch)
2. `SyncEngine` runs the `@vibe-cafe/vibe-usage` CLI via `CLIBridge`
3. `RuntimeDetector` finds Node.js or Bun on the system
4. After sync completes, `fetchUsageData()` refreshes the dashboard
5. Opening the popover calls `fetchUsageDataIfNeeded()` (60s debounce) — fetch only, no upload

### Rate-Limit Refresh
No background timer. `RateLimitCoordinator` is driven entirely by user-visible events:
- Settings exposes separate persisted provider toggles: `codexRateLimitEnabled` (default on, with legacy `rateLimitMonitoringEnabled` fallback) and `claudeRateLimitEnabled` (default off). If both are off, no `RateLimitCoordinator` is started and the quota section is hidden entirely.
- Popover open → enabled providers only: `refreshCodexIfNeeded()` and/or `refreshClaudeIfNeeded()` (60s debounce each). Neither path can prompt the user for anything.
- Footer "更新数据" / card retry buttons → `refreshAll()` (parallel; the coordinator still skips disabled providers).
- **Codex is network-first with a local fallback.** `CodexUsageAPI` GETs the zero-quota usage endpoint (`{base}/wham/usage`, base honors `chatgpt_base_url` in `~/.codex/config.toml` and `$CODEX_HOME`) with the OAuth access token + account id from `~/.codex/auth.json` — a plain-file read, no keychain, no prompts. This keeps the card fresh while Codex is idle and adds facts the JSONL can't provide: live `plan_type`, "window not enforced" semantics (see below), and `rate_limit_reset_credits`. The refresh chain: paint the *last live snapshot* instantly if the card is empty (persisted to `~/.vibe-usage/codex-rate-limits.json` as a minimal DTO; a SHA-256 scope binds it to the active account + endpoint without storing either raw value; expired windows and snapshots over 7 days old are rejected) → live fetch (3 attempts, backoff, 10s timeout) → on 401 re-read auth.json once and retry when either token or account changed → still-401 falls back to JSONL or surfaces `.unauthorized` → transport errors fall back to `CodexRateLimitReader`'s session-JSONL scan. Refreshes are single-flight and cancelled when the panel closes; a fallback replaces an existing `.ok` snapshot only when its `dataAsOf` is newer, so degraded reads cannot make displayed usage go backwards. The JSONL scan is thus entirely off the happy path — it runs only on fetch failure.
- **Claude delegates the live read to a Claude Code binary.** `ClaudeUsageProbe` spawns one (`--safe-mode --no-session-persistence --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools "" --output-format stream-json --input-format stream-json --verbose`), sends `initialize` then `get_usage` over the stdio control protocol, and parses the reply: `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` (each with `utilization` + ISO-8601 `resets_at`), `extra_usage`, and `subscription_type` for the plan badge. ~2.5s, zero tokens (no prompt is ever sent), no keychain prompt — the binary reads its own credentials. Binary discovery goes `VIBE_USAGE_CLAUDE_BIN` → user-installed CLI (`~/.local/bin/claude` and friends) → the copy Claude Desktop manages (`~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`, newest version; that directory changes on every Desktop update so it must be resolved by listing, not hardcoded). The Desktop bundle is deliberately **last**: it exists to cover machines with no CLI at all and must not take over on machines that have one. Each candidate is tried in turn. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` **must** be stripped from the child environment — it suppresses the usage fetch and makes the probe answer `rate_limits: null`. `CLAUDE_CONFIG_DIR` is preserved. `rate_limits_available: false` (API key / Bedrock / Vertex) is a permanent answer and collapses the card; a null `rate_limits` on a subscription account is retryable and falls back to cache.
- **This replaced the statusline capture hook, which could never work for Claude Desktop.** Claude Code builds the statusline payload inside its *terminal* render loop; Desktop hosts sessions through the SDK and never invokes a `statusLine.command`, so Desktop-only users saw a permanently empty card while their token stats worked fine. `LegacyStatuslineRetirement` hands the `~/.claude/settings.json` edit back on launch (restoring the command saved in `~/.vibe-usage/statusline-original`, else removing the key) and deletes the generated wrapper/sidecar/capture files; it deliberately keeps `settings.json.vibe-bak`, the only copy of the user's pre-edit settings. `claudeRateLimitEnabled` is now a plain display toggle defaulting to on, like Codex — a one-time migration flips the old stored `false` (which usually just meant "never clicked 启用") to on. Keychain + `api.anthropic.com/api/oauth/usage` remains a dead end: that ACL binds to the app's code signature, so every re-sign re-prompts (removed in 87e1061).
- **Two on-disk caches paint the Claude card instantly.** `ClaudeUsageCache.configSnapshot()` reads `cachedUsageUtilization` from `~/.claude.json` — written by any Claude Code session including the ones Desktop spawns, and by our own probe, but *not* by Desktop's Electron process (which polls `/api/organizations/{org}/usage` instead). It carries `resets_at`, so it can drive the reset countdown; the account is verified against `oauthAccount.accountUuid` in the same file, already-reset windows drop their `windowDuration`, and a 7-day hard bound applies. `desktopHistorySnapshot()` is the last resort: Desktop's `plan-usage-history.json` (30-day ring, 4.5-min append throttle, keys `fh`/`sd`/`so`/`sn`) has **no `resets_at` at all**, and the 5-minute poll feeding it is gated on the user enabling Desktop's own menu-bar usage indicator — so freshness cannot be assumed and a sample is dropped once it is older than the window it describes.
- **Freshness surfaces in the UI, not just logs.** `ProviderRateLimit.dataAsOf` records when the numbers were produced (live fetch ≈ now; Codex JSONL event timestamp; Claude's own `fetchedAtMs` / Desktop's sample time). A minute-driven `TimelineView` makes the card footer show and continuously update 「数据截至 N 分钟前」 once age exceeds 5 minutes, plus 「重置券 ×N」 when Codex reports available reset credits. `isCodexRateLimitRefreshing` / `isClaudeRateLimitRefreshing` on AppState drive a mini spinner in the card header while a refresh is in flight (Codex ~1s of network latency, Claude ~2.5s of subprocess round trip).
- **"Not enforced" vs "no data" for the Codex 5h window.** The endpoint reports enforced windows exhaustively, so an absent/null 5h window there means OpenAI switched the limit off (they did on 2026-07-12) — `fiveHourNotEnforced` renders the reserved paid-plan 5h slot as 「官方当前未启用」. A present but malformed window makes the entire live response unparseable and triggers fallback; it is never treated as proof of non-enforcement. A JSONL snapshot can't make that claim either (a missing window may just mean idle >5h), so its placeholder stays 「近 5 小时无活动」.
- Display: `RateLimitCardView` hides providers the user turned off. A cold `.noData` stays visible as 「正在读取订阅配额…」 while that provider's refresh is in flight (both legs now have real latency); both showing → side-by-side cards, only one → single full-width card, neither enabled → no quota section.
- A settled Claude `.noData` (probe found no binary, could not reach the endpoint, and no cache existed) keeps a 「暂无订阅配额数据」 row with a retry button rather than collapsing, since it is usually fixable. `.disabled` is unreachable now and only survives as a landing for snapshots persisted by pre-0.5.7 builds.
- Terminology: code stays on `RateLimit` (matches the `rate_limits` field both providers return); user-facing copy uses 「订阅配额」. Settings toggles should use display-oriented copy: 「显示 Codex 订阅配额」 / 「显示 Claude 订阅配额」. When `ClaudeUsageProbe.primarySourceKind() == .desktop` (Desktop installed, no CLI) the Claude toggle gets a 「数据来源：Claude Desktop」 subtitle — the one case where the data comes from something the user did not install themselves. With a CLI present there is nothing to explain and the note stays hidden; it resolves once at launch (`AppState.claudeUsesDesktopBundledCLI`) since it only depends on what is on disk.
- `RateLimit.swift`'s `sevenDayOpus`/`sevenDaySonnet`/`extraUsage` are populated by the Claude probe (Max plans expose the per-model weekly windows); the card does not render them yet. `.unauthorized` is real again: `CodexUsageAPI` maps a post-reload 401 to it, and the card renders a re-login hint with a retry button.
- **Codex JSONL staleness policy (stricter than Claude's).** Codex's `rate_limits.primary/secondary.resets_at` is anchored to a true rolling window, so a `resets_at` already in the past proves that window has rolled over and the snapshot's `used_percent` is from the *previous* window. `CodexRateLimitReader.parseWindow` drops any such slot (per-window — 5h and 7d expire independently), and `read()` returns `.noData` if both slots are expired so the card collapses. Without this filter the reader would display a stale percentage indefinitely (e.g. an 8% reading hanging around 12 days after that window's `resets_at`). The Claude reader is intentionally more lenient — it keeps `used_percentage` and only suppresses the elapsed-time bar when stale — because Claude's payload has no equivalent "this window has provably rolled" signal; staleness there just means Claude Code is idle (and the 「数据截至」 footer note communicates the age).

### Settings Window
Settings uses a raw `NSWindow` via `SettingsWindowController`. The SwiftUI `Settings` scene stays as a placeholder to satisfy the `App` protocol; the actual settings surface is managed directly so it behaves consistently alongside the custom dashboard panel.

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

## Styling Conventions

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
- All UI text in Chinese
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

### 2. Commit and Push

```bash
git add -A && git commit -m "bump version to X.Y.Z" && git push
```

### 3. Build + Sign + Notarize

```bash
./scripts/build-app.sh --notarize
```

Produces in `dist/`:
- `Vibe Usage.app` — signed + notarized app bundle
- `VibeUsage.dmg` — distribution disk image (user download)
- `VibeUsage.zip` — update archive (Sparkle downloads this)

### 4. Generate Appcast

```bash
./scripts/generate-appcast.sh
```

Reads `dist/VibeUsage.zip`, signs with Ed25519 key from Keychain, writes `dist/appcast.xml`.

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

- **Identity**: `Developer ID Application: Yin Ming (D33463FWDZ)`
- **Notarization profile**: `VibeUsage` (stored in Keychain via `notarytool store-credentials`)
- **Sparkle Ed25519 key**: In Keychain, used by `generate_appcast` automatically
- **Sparkle public key**: In `Info.plist` as `SUPublicEDKey`
- The build script signs Sparkle internals inside-out, then the framework, then the app bundle

### Releasing From Another Mac — Mandatory Sparkle-Key Check

- The Sparkle key was rotated for `v0.5.4`. All later releases must use the private key matching the current `SUPublicEDKey` in `VibeUsage/Info.plist`; an older release Mac may still hold the retired key.
- Before every release, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p` and compare it with `/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' VibeUsage/Info.plist`. They must match before `generate-appcast.sh` runs.
- If the key is absent or mismatched, **stop**. Do not generate or rotate a key merely to make the release pass. Import the current private key from the secure backup or another authorized release Mac using `generate_keys -f <private-key-file>`.
- To provision another release Mac, export from a Mac holding the current key with `generate_keys -x <private-key-file>`, transfer it through an encrypted channel, import it, verify the public-key match, and then remove or securely archive the transfer copy. Never commit the exported key.
- Also verify that the destination Mac has the Developer ID private key and a working `VibeUsage` notarization profile. See `docs/RELEASING.md` for the complete migration checklist.
- A deliberate future key rotation requires explicit authorization and an update-path validation against the currently released app; it is not routine release-machine setup.

## Known Constraints

- LSUIElement apps cannot use SwiftUI `Settings` scene — must use NSWindow directly
- `swift run` skips Sparkle initialization (no Info.plist in non-bundle builds)
- Debug builds (`#if DEBUG`) use `localhost:3000` and `config.dev.json`
- Requires Node.js or Bun on the user's system for CLI sync to work
