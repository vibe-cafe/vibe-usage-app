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
│   │   ├── SummaryCardsView.swift # 5 stat cards (cost, total, input, output, cached)
│   │   ├── BarChartView.swift     # Custom-drawn bar chart (hourly/daily trend)
│   │   ├── DistributionChartsView.swift  # 4 donut pie charts (terminal, tool, model, project)
│   │   ├── FilterTagsView.swift   # Filter pills for source/model/project/hostname
│   │   ├── MenuBarIcon.swift      # Menu bar icon with sync status
│   │   └── SettingsView.swift     # Settings form (API key, menu bar prefs, auto-start, updates)
│   ├── Services/
│   │   ├── APIClient.swift        # HTTP client for /api/usage (Bearer auth with vbu_ key)
│   │   ├── SyncEngine.swift       # Orchestrates CLI sync (runs @vibe-cafe/vibe-usage via Node/Bun)
│   │   ├── SyncScheduler.swift    # 5-minute interval auto-sync timer
│   │   ├── CLIBridge.swift        # Executes vibe-usage CLI as subprocess
│   │   ├── RuntimeDetector.swift  # Finds Node.js or Bun runtime on the system
│   │   ├── UpdaterViewModel.swift # Sparkle SPUUpdater bridge for SwiftUI
│   │   └── SettingsWindowController.swift  # NSWindow wrapper (LSUIElement keyboard workaround)
│   ├── Utils/
│   │   ├── Formatters.swift       # Number, cost, date, time formatting
│   │   └── Log.swift              # Debug logging
│   └── Resources/
│       └── Assets.xcassets/       # App icon, menu bar icon
├── scripts/
│   ├── build-app.sh               # Build + sign + notarize pipeline
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
./scripts/build-app.sh                   # Build + codesign .app
./scripts/build-app.sh --notarize        # Full pipeline: build + sign + notarize + DMG
./scripts/generate-appcast.sh            # Generate appcast.xml from dist/VibeUsage.zip
```

## Architecture

### App Type
LSUIElement menu bar app — no dock icon, no main window. Uses `MenuBarExtra` with `.window` style for the popover dashboard.

### State Management
`AppState` is `@Observable` and injected via `@Environment`. All views read from it. No Combine, no ObservableObject (except `UpdaterViewModel` which bridges Sparkle's KVO).

### View Hierarchy
```
VibeUsageApp (MenuBarExtra)
└── PopoverView (520px wide)
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
1. `SyncScheduler` fires every 5 minutes
2. `SyncEngine` runs the `@vibe-cafe/vibe-usage` CLI via `CLIBridge`
3. `RuntimeDetector` finds Node.js or Bun on the system
4. After sync completes, `fetchUsageData()` refreshes the dashboard

### Settings Window
Settings uses a raw `NSWindow` via `SettingsWindowController` because SwiftUI `Settings` scenes don't work in LSUIElement apps. The window temporarily sets `NSApp.setActivationPolicy(.accessory)` for keyboard input, reverts to `.prohibited` on close.

### Auto-Updates (Sparkle)
- `SPUStandardUpdaterController` initialized in `UpdaterViewModel`
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

    var computedTotal: Int           // inputTokens + outputTokens + reasoningOutputTokens
    var dayKey: String               // "yyyy-MM-dd" from bucketStart
    var hourKey: String              // "yyyy-MM-ddTHH" from bucketStart
}
```

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
- Window level: `.normal` (not `.floating`) — `.floating` hides Sparkle update dialogs

## Release Process

### 1. Bump Version — THREE locations, all required

| File | Field | What |
|------|-------|------|
| `VibeUsage/Models/AppConfig.swift` | `static let version` | Display version (e.g. `"0.2.3"`) |
| `VibeUsage/Info.plist` | `CFBundleShortVersionString` | Must match AppConfig (e.g. `0.2.3`) |
| `VibeUsage/Info.plist` | `CFBundleVersion` | Build number, **must increment** (e.g. `4`) |

`CFBundleVersion` is the integer Sparkle compares. If you only bump the display version but forget this, Sparkle will not detect the update.

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

### Common Release Mistakes

| Mistake | Symptom |
|---------|---------|
| Forgot to increment `CFBundleVersion` in Info.plist | "X.Y.Z is currently the newest version" |
| Forgot `generate-appcast.sh` | Sparkle feed still lists old version |
| Forgot to upload `appcast.xml` to release | "An error occurred in retrieving update information" |
| Deleted `VibeUsage.zip` from release | Sparkle update download fails |
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
