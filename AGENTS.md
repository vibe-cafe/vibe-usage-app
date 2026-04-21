# AGENTS.md

AI agent guidance for the vibe-usage-app repository.

## Repository Map

```
vibe-usage-app/                    # SwiftUI macOS menu bar app (SPM, Swift 6, macOS 14+)
├── Package.swift                  # SPM manifest (Sparkle dependency)
├── VibeUsage/
│   ├── Info.plist                 # Bundle metadata (versions, Sparkle SUFeedURL, SUPublicEDKey)
│   ├── App/
│   │   ├── VibeUsageApp.swift     # @main entry, MenuBarExtra scene
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
│   │   └── SettingsView.swift     # Settings form (API key, menu bar prefs, auto-start, updates)
│   ├── Services/
│   │   ├── APIClient.swift        # HTTP client for /api/usage (Bearer auth with vbu_ key)
│   │   ├── SyncEngine.swift       # Orchestrates CLI sync (runs @vibe-cafe/vibe-usage via Node/Bun)
│   │   ├── SyncScheduler.swift    # 30-minute interval auto-sync timer
│   │   ├── CLIBridge.swift        # Executes vibe-usage CLI as subprocess
│   │   ├── RuntimeDetector.swift  # Finds Node.js or Bun runtime on the system
│   │   ├── UpdaterViewModel.swift # Sparkle SPUUpdater bridge + SPUUpdaterDelegate proxy (publishes availableUpdate)
│   │   ├── MenuBarController.swift # NSStatusItem + custom borderless popover panel (multi-line title, animated open/close)
│   │   ├── PopoverPanel.swift     # NSPanel subclass that becomes key for TextField input
│   │   ├── SettingsWindowController.swift  # NSWindow wrapper (LSUIElement keyboard workaround)
│   │   └── ActivationCoordinator.swift     # Centralizes NSApp.activationPolicy across popup + Settings
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
LSUIElement menu bar app — no dock icon, no main window. `AppDelegate` owns a `MenuBarController` that manages an `NSStatusItem` plus a borderless `PopoverPanel` (custom NSPanel) hosting the SwiftUI dashboard. We dropped `MenuBarExtra` so the status item can render multi-line text via `NSHostingView` (cost over tokens) and the panel can use a custom open/close animation anchored to the icon.

### State Management
`AppState` is `@Observable` and injected via `@Environment`. All views read from it. No Combine, no ObservableObject (except `UpdaterViewModel` which bridges Sparkle's KVO).

### View Hierarchy
```
VibeUsageApp → AppDelegate → MenuBarController (NSStatusItem + PopoverPanel)
└── PopoverView (520px wide, hosted in NSHostingView pinned to panel.contentView)
    ├── unconfiguredView          # First-run API key setup
    └── dashboardView
        ├── headerBar             # Title, "查看详情" link, time range (1D/7D/30D), settings gear
        ├── ScrollView
        │   ├── FilterTagsView    # Source/model/project/hostname filter pills
        │   ├── SummaryCardsView  # 5 stat cards
        │   ├── BarChartView      # Trend chart (hourly or daily)
        │   └── DistributionChartsView  # 4 donut charts (2x2 grid)
        └── footerBar             # Sync status, refresh, quit
```

### Data Flow
1. `APIClient.fetchUsage(days:)` fetches from `/api/usage` with Bearer token auth
2. Response decoded into `[UsageBucket]`, stored in `AppState.buckets`
3. Views compute filtered data locally: `appState.buckets.filter { ... appState.filters ... }`
4. Charts aggregate filtered buckets by time key or dimension

### Sync Pipeline
1. `SyncScheduler` fires every 30 minutes (background upload + fetch)
2. `SyncEngine` runs the `@vibe-cafe/vibe-usage` CLI via `CLIBridge`
3. `RuntimeDetector` finds Node.js or Bun on the system
4. After sync completes, `fetchUsageData()` refreshes the dashboard
5. Opening the popover calls `fetchUsageDataIfNeeded()` (60s debounce) — fetch only, no upload

### Settings Window
Settings uses a raw `NSWindow` via `SettingsWindowController` because SwiftUI `Settings` scenes don't work in LSUIElement apps. Opening Settings promotes `NSApp.activationPolicy` to `.regular` (dock icon + click-to-front behavior); `ActivationCoordinator` reverts to `.accessory` / `.prohibited` on close depending on whether the menu-bar popup is still open.

### ActivationCoordinator
`NSApp.activationPolicy` has to change depending on which surface is visible:
- popup only → `.accessory` (so `TextField` can receive key events)
- Settings visible → `.regular` (so the window behaves like a normal app window)
- neither → `.prohibited` (true LSUIElement)

`ActivationCoordinator` is the only place that calls `setActivationPolicy`. Without it, closing one surface could strand the other — e.g. dismissing the popup would drop the app to `.prohibited` and AppKit would tear down the still-visible Settings window. It also emits `onSettingsVisibilityChange`, which `MenuBarController` uses to lower the popover panel from `.popUpMenu` to `.normal` while Settings is visible (so standard z-ordering lets a click on Settings bring it forward).

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

    var computedTotal: Int           // inputTokens + outputTokens + reasoningOutputTokens (excludes cachedInputTokens, matches web "总 Token")
    var dayKey: String               // "yyyy-MM-dd" from bucketStart
    var hourKey: String              // "yyyy-MM-ddTHH" from bucketStart
}
```

Token aggregation conventions (aligned with the web Vibe Usage page):
- Popup summary "总 Token" card → `computedTotal` (no cache reads)
- Popup summary "缓存 Token" card → `cachedInputTokens` (cache reads only)
- Menu-bar token line → `computedTotal + cachedInputTokens` (sum of both, so cache reads are visible in the single-number menu-bar display)
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

## Known Constraints

- LSUIElement apps cannot use SwiftUI `Settings` scene — must use NSWindow directly
- `swift run` skips Sparkle initialization (no Info.plist in non-bundle builds)
- Debug builds (`#if DEBUG`) use `localhost:3000` and `config.dev.json`
- Requires Node.js or Bun on the user's system for CLI sync to work
