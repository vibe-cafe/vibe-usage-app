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
│   │   └── Config.swift           # Shared ~/.vibe-usage config; app-owned fields + unknown CLI-field-preserving writes
│   ├── Views/
│   │   ├── PopoverView.swift      # Main dashboard container (520px wide popover)
│   │   ├── SummaryCardsView.swift # 5 stat cards (cost, total tokens, cached tokens, active duration, total duration)
│   │   ├── BarChartView.swift     # Custom-drawn bar chart (hourly/daily trend)
│   │   ├── DistributionChartsView.swift  # 4 donut pie charts (terminal, tool, model, project)
│   │   ├── FilterTagsView.swift   # Filter pills for source/model/project/hostname
│   │   ├── SettingsView.swift     # Grouped settings form: 订阅配额 toggles, 常规 (menu bar/Dock/auto-start), 数据同步, 数据目录（高级）collapsed disclosures, updates, reset
│   ├── Services/
│   │   ├── APIClient.swift        # HTTP client for /api/usage (Bearer auth with vbu_ key) + unauthenticated device-flow helpers (requestDeviceCode/pollDeviceCode)
│   │   ├── SyncEngine.swift       # Orchestrates CLI sync (runs @vibe-cafe/vibe-usage via Node/Bun)
│   │   ├── SyncScheduler.swift    # 30-minute interval auto-sync timer
│   │   ├── CLIBridge.swift        # Executes vibe-usage CLI config commands
│   │   ├── CLIProcessRunner.swift # Background process wait, temporary output files, explicit deadlines
│   │   ├── RuntimeDetector.swift  # Finds Node.js or Bun runtime on the system
│   │   ├── UpdaterViewModel.swift # Sparkle SPUUpdater bridge + SPUUpdaterDelegate proxy (publishes availableUpdate)
│   │   ├── RateLimitCoordinator.swift # Orchestrates quota refreshes (cache-then-live for both providers)
│   │   ├── CodexUsageAPI.swift    # Live Codex usage endpoint client (auth.json token, zero-quota GET)
│   │   ├── CodexRateLimitReader.swift # Offline Codex fallback: session-JSONL scan
│   │   ├── ClaudeUsageProbe.swift # Live Claude quota: spawns a Claude Code binary, stdio `get_usage`
│   │   ├── ClaudeUsageCache.swift # Claude instant-paint: ~/.claude.json, then Desktop's usage history
│   │   ├── OpenCodeGoUsageAPI.swift # Live OpenCode Go quota: reads the CLI's own auth.json key, GET /zen/go/v1/usage
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
│   ├── build-app.sh               # Build + sign + notarize pipeline; supports --universal / --arch
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
./scripts/build-app.sh                   # Build + codesign .app for host arch (runs check-version.sh first)
./scripts/build-app.sh --universal       # Build universal (arm64 + x86_64) .app
./scripts/build-app.sh --universal --notarize  # Release pipeline: universal + sign + notarize + DMG
./scripts/generate-appcast.sh            # Generate appcast.xml from dist/VibeUsage.zip
```

## Architecture Approval Gate

Issues and PRs are proposals, not approval to change architecture or ship a
release. Explicit maintainer approval is required before changing privacy or
security semantics, defaults/onboarding, identity/dedup behavior, source of
truth, cross-repository API/config contracts, or automatic update behavior.
This remains true during a broad issue sweep.

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
build (integration tests). Before approval, present the current and proposed
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
Multi-day API buckets carry UTC instants for the viewer's local midnight. Daily bucket/session keys must convert those instants through the current timezone; taking the raw ISO prefix shifts UTC+ users back one day and leaves today's 7D bar empty.

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

`scripts/check-cli.mjs` validates the actual npm package (current `latest`) before normal `build-app.sh` packaging. It requires schema v1 discovery/fetch for Kimi, ZCode, and Grok, with Cursor discovery-only, using isolated credential-free directories. `--from-local` validates a packed checkout for pre-publish integration or the explicit external-test build; it must never bypass the published-package check for an ordinary app. See `docs/RELEASING.md` for CLI-before-app ordering.

1. `SyncScheduler` fires every 30 minutes (background upload + fetch)
2. `SyncEngine` runs the `@vibe-cafe/vibe-usage` CLI via `CLIBridge`
3. `RuntimeDetector` finds Node.js or Bun on the system
4. After sync completes, `fetchUsageData()` refreshes the dashboard
5. Opening the popover calls `fetchUsageDataIfNeeded()` (60s debounce) — fetch only, no upload
6. Settings can persist one legacy `codexExtraHome` plus per-source isolated runtime roots (Codex / Grok / Antigravity, e.g. Multica homes) through the CLI (`config roots` / `add-root` / `remove-root`, CLI ≥ 0.10.20) — both editors sit in the collapsed 数据目录（高级）group; sync then scans them together with each tool's default directory (`$CODEX_HOME` / `~/.codex` for Codex). The app never writes these fields itself — `CLIBridge` shells out so the CLI stays the single writer. Config writes must preserve unknown CLI fields, especially local privacy controls and `deviceId`. `VIBE_USAGE_CONFIG_DIR` / `VIBE_USAGE_CLI_PACKAGE` are integration-test hooks (the latter forces `npx` with a local package path).

CLI subprocesses use `CLIProcessRunner`: blocking waits run on a dispatch worker, stdout/stderr go to private temporary files (removed after completion), and deadlines are reported as timeout rather than launcher stderr. Never wait for a subprocess to exit before draining `Pipe` output: a full pipe deadlocks the child, and an inherited pipe can outlive it. A one-second SIGTERM grace period is followed by SIGKILL for an unresponsive process. Exit zero remains success even when Bun prints dependency-resolution progress to stderr.

### Rate-Limit Refresh
No background timer. `RateLimitCoordinator` is driven entirely by user-visible events:
- **Approved 2026-09-19 — quota meter layout:** generic time windows render first from shortest to longest, so every provider that has both windows shows `5h` above `7d`. Exact generic aliases normalize to compact labels (`Daily` → `1d`, `Weekly` / `1w` → `7d`); provider-specific/model/feature meters retain their relative order afterward. The CLI canonicalizes schema-v1 live/cache results and both desktop apps repeat the rule defensively for older snapshots. Providers without a 5h window start with their first real window; the UI never invents an empty slot.
- The dashboard and Settings share one ordered, persisted product selection (`selectedQuotaProductIds`), with **no display cap**: every enabled product keeps its own card and the row scrolls sideways once it is wider than the popover. First launch selects locally detected ready products; a one-time migration preserves the legacy Codex/Claude toggles exactly, while the former stored `cursor-grok` id maps to Cursor (never to the newly fetchable Grok adapter). `quotaSelectionInitialized` distinguishes a fresh install from a user intentionally selecting nothing. Local discovery never reads credentials or reaches the network, and a product discovered after initialization never replaces the user's choices. `codexRateLimitEnabled` / `claudeRateLimitEnabled` are compatibility projections over this selection while their native adapters remain in place.
- `QuotaProductRegistry` lists Kimi Code, ZCode, Grok, and Cursor independently and recognizes ordinary local app/config/CLI presence without opening credentials. Kimi, ZCode, and Grok use the CLI's schema-versioned quota contract. Grok reads at most the final 2 MiB of its official CLI's ordinary `~/.grok/logs/unified.jsonl`, accepts only the structured `billing: fetched credits config` event, and projects only utilization, current-period bounds, subscription tier, and event timestamp; it performs no network request and never returns, caches, logs, or uploads other log fields. Cursor is manually selectable when detected but stays out of first-launch auto-selection and displays a pending card until an official stable quota protocol exists; selecting it starts no subprocess or request. Never scrape browser cookies, Cursor login tokens/databases, another app's keychain, network traffic, or UI.
- Kimi reads the official Kimi Code 2.x OAuth file (`$KIMI_CODE_HOME/credentials/kimi-code.json`, otherwise `~/.kimi-code/credentials/kimi-code.json`) through the shared CLI, with the legacy `$KIMI_SHARE_DIR` / `~/.kimi` file as fallback, and calls the official `/coding/v1/usages` endpoint. The adapter accepts the current 2.x `usages` response and the legacy quota response. The shared CLI is the sole Vibe-side owner of Kimi refresh behavior: when the access token is near expiry or a usage request returns 401, it uses Kimi's standard OAuth refresh grant, serializes Vibe refreshes across processes, re-checks concurrent Kimi CLI rotation, and atomically writes the rotated credential at mode `0600`. No token reaches app output, diagnostics, quota cache, or upload state. ZCode accepts only a user-entered regional API key. BigModel (domestic) and Z.ai (overseas) use separate Vibe Usage Keychain items; the app removes both inherited variables, injects only `BIGMODEL_API_KEY` or `Z_AI_API_KEY` for the explicitly selected region, and never reads ZCode's OAuth database. Existing Z.ai keys remain assigned to Z.ai; a fresh configuration displays BigModel by default but performs no request until the user saves a key and selects ZCode. Normalized CLI quota cache entries are scoped by a one-way hash of region plus credential and contain no secrets. The Mac validates `schemaVersion == 1` before displaying results, so a CLI contract mismatch fails closed per card.
- **OpenCode Go is app-native, not CLI-backed** (2026-09-26, the mode the maintainer chose). `OpenCodeGoUsageAPI` reads OpenCode's own Go API key — the `opencode-go` integration row in `~/.local/share/opencode/opencode.db` first (read-only, only that row's `value`), falling back to the plain-text `~/.local/share/opencode/auth.json` (`opencode.key`) that the pre-2.x layout writes — and calls the account-wide `GET https://opencode.ai/zen/go/v1/usage`, mapping its `rolling` / `weekly` / `monthly` percentages onto `ProviderRateLimit.meters` (labels 5h / Weekly / Monthly). `windowDuration` is stated only for the fixed 5h and 7-day windows; the monthly reset is a calendar month, so that row carries no duration and therefore no "% elapsed" bar rather than a guessed one. The key is read per request, sent only as a bearer header, and never logged, cached, uploaded, or written; the app never rewrites OpenCode's credential and never reads OpenCode's conversation store, only the credential entry `opencode` — other provider credentials in that file stay uninspected. There is deliberately **no on-disk snapshot cache** (unlike Codex): the file carries no account identity a cache could be scoped to, and the call is one fast request, so a cold card shows its spinner instead of risking another login's numbers. A 403 `EntitlementError` is the endpoint's answer, not a failed read: it maps `FetchError.notSubscribed → .notApplicable`, which the coordinator turns into `.noData` with `EmptyReason.notEntitled` (「未订阅 OpenCode Go」) and no retry affordance, while 401 asks the user to re-login in OpenCode itself. It never appears in `usesQuotaCLI`, so the CLI envelope can neither carry nor be asked for it; selection, detection (`~/.local/share/opencode`), and the popover-open refresh (`refreshOpenCodeGoIfNeeded`) use the same product registry and path as every other card.- Exportable diagnostics are a test-build facility only. `TestDiagnosticLog` and the Settings export UI must remain guarded by `#if DEBUG` or the explicit external-test build flag, so ordinary Release binaries contain neither log writes nor an export entry. The JSONL schema is typed and may contain only error codes, detected/selected provider ids, status/meter counts, timestamps, app/OS versions, build kind/number, and reviewed App/CLI version or commit identifiers; never add raw stderr, response bodies, request headers, credentials, account identifiers, environment overrides, or filesystem paths. Files stay inside the current user's `~/Library/Logs/Vibe Usage/`, use owner-only permissions, and are shared only when that user explicitly exports them. A locally re-signed Debug UI build may set `VIBE_USAGE_TEST_KEYCHAIN_SERVICE` to an empty test namespace so it never queries the release app's ZCode items or triggers an approval prompt, and `VIBE_USAGE_QUOTA_UI_TEST=1` to show the quota dashboard without loading the production Vibe account config or starting its sync/upload scheduler. Both hooks must remain inside `#if DEBUG`; Release always uses `ai.vibecafe.vibe-usage` and its normal account lifecycle.
- Popover open → selected providers only: native Codex/Claude plus the Kimi/ZCode/Grok CLI adapters (60s debounce per provider). Cursor never joins the refresh fan-out. Neither path can prompt the user for another product's credentials.
- Footer "更新数据" → `refreshAll()` (parallel; the coordinator still skips disabled providers). A card-level retry refreshes only that provider.
- **Codex is network-first with a local fallback.** `CodexUsageAPI` GETs the zero-quota usage endpoint (`{base}/wham/usage`, base honors `chatgpt_base_url` in `~/.codex/config.toml` and `$CODEX_HOME`) with the OAuth access token + account id from `~/.codex/auth.json` — a plain-file read, no keychain, no prompts. This keeps the card fresh while Codex is idle and adds facts the JSONL can't provide: live `plan_type`, "window not enforced" semantics (see below), and `rate_limit_reset_credits`. The refresh chain: paint the *last live snapshot* instantly if the card is empty (persisted to `~/.vibe-usage/codex-rate-limits.json` as a minimal DTO; a SHA-256 scope binds it to the active account + endpoint without storing either raw value; expired windows and snapshots over 7 days old are rejected) → live fetch (3 attempts, backoff, 10s timeout) → on 401 re-read auth.json once and retry when either token or account changed → still-401 falls back to JSONL or surfaces `.unauthorized` → transport errors fall back to `CodexRateLimitReader`'s session-JSONL scan. Refreshes are single-flight and cancelled when the panel closes; a fallback replaces an existing `.ok` snapshot only when its `dataAsOf` is newer, so degraded reads cannot make displayed usage go backwards. The JSONL scan is thus entirely off the happy path — it runs only on fetch failure.
- **Claude delegates the live read to a Claude Code binary.** `ClaudeUsageProbe` spawns one (`--print --safe-mode --no-session-persistence --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools "" --output-format stream-json --input-format stream-json --verbose --settings '{"env":{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":""}}'`), sends `initialize` then `get_usage` over the stdio control protocol, and parses the reply: `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` (each with `utilization` + ISO-8601 `resets_at`), `extra_usage`, and `subscription_type` for the plan badge. ~2.5s, zero tokens (no prompt is ever sent), no keychain prompt — the binary reads its own credentials. Binary discovery goes `VIBE_USAGE_CLAUDE_BIN` → user-installed CLI (`~/.local/bin/claude`, `~/.claude/local/claude`, the Homebrew prefixes, then every `$PATH` directory — `$PATH` matters because `QuotaProductRegistry` already counts a PATH `claude` as 「已检测」, so omitting it left version-manager installs (nvm/fnm/volta shims) detected but never probed) → the newest copy Claude Desktop manages (`~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`; older retained Desktop versions are not retried). The Desktop bundle is deliberately **last**: it exists to cover machines with no CLI at all and must not take over on machines that have one. Candidates share one 25s overall budget and each gets at most 8s, so an executable that hangs cannot multiply the loading time. Stdout uses cancellable async line iteration; panel close/toggle-off also terminates the active `Process`, so neither a blocked read nor a descendant retaining the pipe can hold the refresh open. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` **must** be stripped from the child environment **and** unset via in-memory `--settings` (empty string, not `"0"`) — Claude Code re-injects the flag from `~/.claude/settings.json` `env` after spawn, which makes `get_usage` answer `rate_limits: null` on a subscription account. The probe never writes that file and never passes `--bare` (that skips the keychain). `CLAUDE_CONFIG_DIR` is preserved. `rate_limits_available: false` (API key / Bedrock / Vertex) is a permanent answer and becomes a `.noData` card with neutral copy — never a retry loop; a null `rate_limits` on a subscription account is retryable and falls back to cache.
- **This replaced the statusline capture hook, which could never work for Claude Desktop.** Claude Code builds the statusline payload inside its *terminal* render loop; Desktop hosts sessions through the SDK and never invokes a `statusLine.command`, so Desktop-only users saw a permanently empty card while their token stats worked fine. `LegacyStatuslineRetirement` hands the `~/.claude/settings.json` edit back on launch (restoring the command saved in `~/.vibe-usage/statusline-original`, else removing the key) and deletes the generated wrapper/sidecar/capture files; it deliberately keeps `settings.json.vibe-bak`, the only copy of the user's pre-edit settings. `claudeRateLimitEnabled` is now a plain display toggle defaulting to on, like Codex — a one-time migration flips the old stored `false` (which usually just meant "never clicked 启用") to on. Keychain + `api.anthropic.com/api/oauth/usage` remains a dead end: that ACL binds to the app's code signature, so every re-sign re-prompts (removed in 87e1061).
- **Two on-disk caches paint the Claude card instantly.** `ClaudeUsageCache.configSnapshot()` reads `cachedUsageUtilization` from `~/.claude.json` — written by any Claude Code session including the ones Desktop spawns, and by our own probe, but *not* by Desktop's Electron process (which polls `/api/organizations/{org}/usage` instead). It carries `resets_at`, so it can drive the reset countdown; the account is verified against `oauthAccount.accountUuid` in the same file, already-reset windows drop their `windowDuration`, and a 7-day hard bound applies. `desktopHistorySnapshot()` is the last resort: Desktop's `plan-usage-history.json` (30-day ring, 4.5-min append throttle, keys `fh`/`sd`/`so`/`sn`) has **no `resets_at` at all**, and the 5-minute poll feeding it is gated on the user enabling Desktop's own menu-bar usage indicator — so freshness cannot be assumed and a sample is dropped once it is older than the window it describes.
- **Freshness surfaces in the UI, not just logs.** `ProviderRateLimit.dataAsOf` records when the numbers were produced (live fetch ≈ now; Codex JSONL event timestamp; Claude's own `fetchedAtMs` / Desktop's sample time). A minute-driven `TimelineView` makes the card footer show and continuously update 「数据截至 N 分钟前」 once age exceeds 5 minutes, plus 「重置券 ×N」 when Codex reports available reset credits. `isCodexRateLimitRefreshing` / `isClaudeRateLimitRefreshing` on AppState drive a mini spinner in the card header while a refresh is in flight (Codex ~1s of network latency, Claude ~2.5s of subprocess round trip).
- **"Not enforced" vs "no data" for the Codex 5h window.** The endpoint reports enforced windows exhaustively, so an absent/null 5h window there means OpenAI switched the limit off (they did on 2026-07-12) — `fiveHourNotEnforced` renders the reserved paid-plan 5h slot as 「官方当前未启用」. A present but malformed window makes the entire live response unparseable and triggers fallback; it is never treated as proof of non-enforcement. A JSONL snapshot can't make that claim either (a missing window may just mean idle >5h), so its placeholder stays 「近 5 小时无活动」.
- Display: a **product tab strip** over a horizontal row of 240pt cards (two per screen, the rest scrolls sideways). The strip is the row's index in *both* directions: clicking a tab scrolls the row to that product (`ScrollViewReader.scrollTo(anchor: .leading)`), and scrolling the row activates the tab of the card that reached the leading edge (`QuotaCardOffsetPreferenceKey` publishes every card's `minX`; the one nearest zero wins, then `selectQuotaTab` persists it). Three tab states, one per monitoring/health combination: monitoring **off** = grey (`saturation 0`, 45% opacity), no card at all, and clicking it opens Settings (that is where monitoring is turned on); monitoring **on but the last read settled on anything other than `.ok`** = full color plus the amber warning dot (`QuotaUtilizationPalette.warning`, suppressed while a refresh is in flight) so the tab points at the card that explains itself; monitoring **on and `.ok`** = plain color. Because only enabled products own a card (`AppState.quotaCardProviders`), an all-off selection leaves the section at the icon row with nothing under it instead of a row of placeholders. The strip lists the whole catalog in the persisted order (`QuotaSelectionPreferences.orderKey`): monitoring-on products first, monitoring-off ones after them, then a bare gear icon that opens the full 订阅配额 settings (toggles, per-product status, ZCode key, 「重新检测本机产品」) — an icon, not a chip, outside the drag order. Tabs are draggable: the stored order *is* the render order (enabled group first), so a cross-group drop normalizes back into the dragged product's own group and dropping past the last tab means the end of that group. Rows share the tallest card's height, so a provider with fewer meters still aligns with its neighbour. Card states: `.ok` renders meters; a cold `.noData` stays visible as 「正在读取订阅配额…」 while that provider's refresh is in flight (both legs now have real latency); a settled `.noData` shows the reason available to it (see below); `.retryableError` (and `.unauthorized`) keep the provider card plus a retry button. A selected Cursor remains visible with 「已识别 Cursor · 等待官方配额接口」 even though it intentionally has no meters. Cards accept provider-neutral meters, render the first three (`RateLimitCardView.compactMeterLimit`), and fold the rest behind a clickable 「另有 N 项」 line that expands the card in place instead of hiding those windows.
- A settled `.noData` explains itself per card instead of hiding: 「本期订阅配额已用满 · 等待额度重置」 when the live Codex endpoint said `limit_reached`/`allowed: false`, 「当前没有生效的额度窗口」 when the endpoint answered without any window (including a null `rate_limit` object, which is an answer — not schema drift — while a *missing* key still fails the parse and falls back), 「暂未读取到订阅配额数据」 when the product is detected locally but no source reported anything, and 「未检测到本机安装或登录」 when local discovery found nothing. Reasons live in `ProviderRateLimit.emptyReason`, set only by sources that can know (the live Codex endpoint); session JSONL, disk caches and other providers leave it nil so the card never invents 「已用满」. A concrete endpoint/probe failure with no cache becomes semantic `.retryableError` (localized in the view) and keeps the provider card plus retry button visible; that retry refreshes only its own provider (Claude retry does not hit Codex, and vice versa). Provider transport errors conform to `RateLimitFetchError`, whose shared classification prevents the coordinator from depending on provider-specific error enums. `.disabled` is unreachable now and only survives as a landing for snapshots persisted by pre-0.5.7 builds. Claude's own definitive answer takes one too: `rate_limits_available: false` (API key / Bedrock / Vertex session) sets `EmptyReason.sessionWithoutPlanLimits`, so the card names the login method instead of reading like a missing install (issue #39).- Terminology: code stays on `RateLimit` (matches the `rate_limits` field both providers return); user-facing copy uses 「订阅配额」. Selector items use the product display name plus local status. When `ClaudeUsageProbe.primarySourceKind() == .desktop` (Desktop installed, no CLI) the Claude row in Settings gets a 「数据来源：Claude Desktop」 subtitle — the one case where the data comes from something the user did not install themselves. With a CLI present there is nothing to explain and the note stays hidden; it resolves once at launch (`AppState.claudeUsesDesktopBundledCLI`) since it only depends on what is on disk.
- `RateLimit.swift`'s `sevenDayOpus`/`sevenDaySonnet`/`extraUsage` are populated by the Claude probe (Max plans expose the per-model weekly windows); the card does not render them yet. `.unauthorized` is real again: `CodexUsageAPI` maps a post-reload 401 to it, and the card renders a re-login hint with a retry button.
- **Codex JSONL staleness policy (stricter than Claude's).** Codex's `rate_limits.primary/secondary.resets_at` is anchored to a true rolling window, so a `resets_at` already in the past proves that window has rolled over and the snapshot's `used_percent` is from the *previous* window. `CodexRateLimitReader.parseWindow` drops any such slot (per-window — 5h and 7d expire independently), and `read()` returns `.noData` if both slots are expired so the card shows its neutral "nothing read yet" line instead. Without this filter the reader would display a stale percentage indefinitely (e.g. an 8% reading hanging around 12 days after that window's `resets_at`). The Claude reader is intentionally more lenient — it keeps `used_percentage` and only suppresses the elapsed-time bar when stale — because Claude's payload has no equivalent "this window has provably rolled" signal; staleness there just means Claude Code is idle (and the 「数据截至」 footer note communicates the age).

### Settings Window
Settings uses a raw `NSWindow` via `SettingsWindowController`. The SwiftUI `Settings` scene stays as a placeholder to satisfy the `App` protocol; the actual settings surface is managed directly so it behaves consistently alongside the custom dashboard panel.

The page is grouped by subject: 数据同步 (account key + sync health) → 订阅配额 (product toggles) → 常规 (menu bar display, auto-start, Dock) → 数据目录（高级）→ [测试诊断, test builds only] → 关于 → 危险操作. Low-frequency and advanced controls live in *collapsed* groups instead of separate sections: the provider notes plus the manual re-detection button inside 订阅配额 (「数据来源与检测」), and both extra-scan-directory editors inside 数据目录（高级）(「额外 Codex Home」/「隔离运行时目录」, whose collapsed labels still surface state as the path or 「N 个目录」). ZCode is the one product row that opens a form: it sits last in the product list, collapsed to an ordinary row (chevron + icon + name + switch), and its expanded form holds only the region picker, the key field and one save/remove action — a user who does not use ZCode never reads about it. Product rows and quota cards share `ProviderIcon` at 14pt, so the two surfaces cannot drift. Collapsing is presentation only — no control was removed, and every row the page exposed before is still one click away.

**Settings copy stays terse.** A label is the shortest direct word (「区域」, 「保存」, 「移除」), and an explanation belongs behind the control it explains or nowhere at all. The judge is whether a first-time user can act without reading prose: the page had grown to ~3.4 screens of stacked sections and multi-sentence footers before this rule, and every added paragraph re-creates that. Add a new setting to an existing group (or behind a collapsed one) rather than appending another section; sync health and 「上次同步」 deliberately share one row for the same reason.

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

### 2. Commit and Push

```bash
git add -A && git commit -m "bump version to X.Y.Z" && git push
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

All three release credentials (Sparkle Ed25519 private key, Developer ID certificate, notarization profile) live on Yin Ming's release Mac only. On any other machine `generate_keys -p` reports "No existing signing key found" — that machine can develop and push to main, but must **not** attempt a release or generate a new key; coordinate with Yin Ming instead.

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
