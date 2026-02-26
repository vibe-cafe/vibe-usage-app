# Vibe Usage

macOS menu bar app for tracking AI coding tool token usage. Syncs data to [vibecafe.ai/usage](https://vibecafe.ai/usage).

Replaces the manual `npx @vibe-cafe/vibe-usage sync` workflow with background polling every 5 minutes.

## Features

- Menu bar app — no Dock icon, runs in the background
- Custom pixel-art menu bar icon (template image, auto light/dark)
- Auto-syncs usage data every 5 minutes via `@vibe-cafe/vibe-usage` CLI
- Dashboard popover with summary cards, stacked bar chart, and multi-category filters
- Inline onboarding with API key validation
- Time range selector: 1D / 7D / 30D
- Menu bar label: optional cost and/or token count next to icon
- Auto-start on login (via SMAppService)
- Manages CLI session hooks (removes on start, restores on quit)

## Requirements

- macOS 14 (Sonoma) or later
- [Node.js](https://nodejs.org) (v20+) or [Bun](https://bun.sh)
- API Key from [vibecafe.ai/usage/setup](https://vibecafe.ai/usage/setup)

## Build

```bash
# Clone
git clone https://github.com/vibe-cafe/vibe-usage-app.git
cd vibe-usage-app

# Build (debug — uses localhost:3000 + config.dev.json)
swift build

# Build (release — uses vibecafe.ai + config.json)
swift build -c release

# Run
swift run
# or
.build/debug/VibeUsage
```

To open in Xcode:

```bash
open Package.swift
```

## Architecture

```
App (SwiftUI MenuBarExtra)
 ├─ reads ~/.vibe-usage/config[.dev].json via ConfigManager
 ├─ writes config directly via ConfigManager.save()
 ├─ calls vibe-usage CLI for sync (via SyncEngine)
 └─ calls GET /api/usage directly for dashboard data (via APIClient)
```

### Debug vs Release

| | Debug (`swift build`) | Release (`swift build -c release`) |
|---|---|---|
| API URL | `http://localhost:3000` | `https://vibecafe.ai` |
| Config file | `~/.vibe-usage/config.dev.json` | `~/.vibe-usage/config.json` |
| CLI env var | `VIBE_USAGE_DEV=1` | (not set) |
| UI badge | Shows "DEBUG" next to title | Hidden |

All debug/release branching flows through `AppConfig.swift` (`#if DEBUG`).

### Key modules

| Module | Purpose |
|--------|---------|
| `AppConfig` | `#if DEBUG` compile-time config (URL, config filename, isDev flag) |
| `AppState` | `@Observable` global state, lifecycle, data fetching |
| `SyncEngine` | Shells out to `npx/bunx @vibe-cafe/vibe-usage sync` |
| `CLIBridge` | Shells out to `vibe-usage config set/get` for config operations |
| `APIClient` | HTTP client for `GET /api/usage` (Bearer auth with API Key) |
| `ConfigManager` | Read/write access to `~/.vibe-usage/config[.dev].json` |
| `HookManager` | Removes/restores CLI session hooks, writes PID marker |
| `SyncScheduler` | GCD timer for 5-minute polling interval |
| `RuntimeDetector` | Finds `bun` or `npx` in PATH and common install locations |

### Views

| View | Purpose |
|------|---------|
| `PopoverView` | Main dashboard with inline onboarding, header, cards, filters, chart, footer |
| `SummaryCardsView` | Cost, total/input/output/cached token cards |
| `FilterTagsView` | Multi-category tag filters (hostname, source, model, project) |
| `BarChartView` | Stacked daily bar chart with hover tooltips |
| `SettingsView` | Menu bar display toggles, auto-start, version, reset |
| `MenuBarIcon` | Custom template icon loaded from PNG bundle resource |

## Config

Shared config at `~/.vibe-usage/config.json` (release) or `config.dev.json` (debug):

```json
{
  "apiKey": "vbu_...",
  "apiUrl": "https://vibecafe.ai",
  "lastSync": "2025-01-01T00:00:00.000Z"
}
```

Both the Mac app and the `@vibe-cafe/vibe-usage` CLI read/write this file.

## Icon

Source SVG at `icon-source.svg`. To regenerate PNGs:

```bash
python3 -m venv /tmp/svg-convert
/tmp/svg-convert/bin/pip install cairosvg
/tmp/svg-convert/bin/python3 generate-icons.py
```

- App icon: `Assets.xcassets/AppIcon.appiconset/` (all macOS sizes)
- Menu bar icon: `Resources/menubar-icon.png` (36x36 @2x, loaded as NSImage template)

## Related

- [@vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) — CLI for parsing and syncing usage data
- [vibecafe.ai/usage](https://vibecafe.ai/usage) — Web dashboard

## License

MIT
